#!/usr/bin/env python3
"""Explicit CPU/GPU LiteRT-LM runner for the native generation worker.

Requires requirements-litert.txt in the selected Python environment. No
downloads, authentication, remote inference or attachment access. Optional
tool calls are delegated over stdin/stdout to the owning application service.
The native worker owns this process group and cancels it on close/timeout.
"""

from typing import Any

import argparse
import ctypes
import copy
import importlib.metadata
import importlib.util
import inspect
import json
import os
import queue
import threading
import time
from contextlib import contextmanager
from pathlib import Path
import sys


def valid_output_budget(budget, definitions):
    if type(budget) is not int:
        return False
    if 1 <= budget <= 3072:
        return True
    return (
        budget == 0
        and isinstance(definitions, dict)
        and definitions.get("tools") == []
        and definitions.get("use_default_output_limit") is True
    )


def merge_stream_message(result, chunk):
    """Merge pinned conversation message deltas without parsing tool arguments."""
    if not isinstance(chunk, dict):
        raise ValueError("Invalid streamed conversation message")
    for key, value in chunk.items():
        if key == "content":
            if isinstance(value, str) and isinstance(result.get(key, ""), str):
                result[key] = result.get(key, "") + value
                continue
            if not isinstance(value, (str, list)):
                raise ValueError("Invalid streamed conversation content")
            previous = result.get(key, [])
            if isinstance(previous, str):
                previous = [{"type": "text", "text": previous}]
            parts = previous
            for part in (
                [{"type": "text", "text": value}] if isinstance(value, str) else value
            ):
                if (
                    isinstance(part, dict)
                    and part.get("type") == "text"
                    and isinstance(part.get("text"), str)
                    and parts
                    and isinstance(parts[-1], dict)
                    and parts[-1].get("type") == "text"
                    and isinstance(parts[-1].get("text"), str)
                    and {k: v for k, v in part.items() if k != "text"}
                    == {k: v for k, v in parts[-1].items() if k != "text"}
                ):
                    parts[-1]["text"] += part["text"]
                else:
                    parts.append(copy.deepcopy(part))
            result[key] = parts
        elif key == "tool_calls":
            if value is None:
                continue
            if not isinstance(value, list):
                raise ValueError("Invalid streamed tool calls")
            result.setdefault(key, []).extend(copy.deepcopy(value))
        elif key == "channels":
            if not isinstance(value, dict) or any(
                not isinstance(v, str) for v in value.values()
            ):
                raise ValueError("Invalid streamed conversation channels")
            channels = result.setdefault(key, {})
            for channel, text in value.items():
                channels[channel] = channels.get(channel, "") + text
        else:
            result[key] = copy.deepcopy(value)


def stream_tool_response(
    conversation, litert_lm, message, budget, emit=None, on_started=None
):
    emit = emit or (
        lambda kind, value: print(
            kind + " " + json.dumps(value, ensure_ascii=False), flush=True
        )
    )
    # The C API owns callback chunks only during the callback. Copy their UTF-8
    # into an ordered queue, then parse/emit on the worker's main thread.
    pending: queue.Queue[Any] = queue.Queue()
    lib = conversation._lib
    callback_type = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)

    @callback_type
    def callback(unused, pointer):
        try:
            error = lib.litert_lm_stream_chunk_get_error(pointer)
            text = lib.litert_lm_stream_chunk_get_text(pointer)
            pending.put(
                (
                    text.decode("utf-8") if text else "",
                    lib.litert_lm_stream_chunk_is_final(pointer),
                    error.decode("utf-8") if error else None,
                )
            )
        except Exception as error:
            pending.put(("", True, str(error)))

    # Match the SDK's callback ownership across native cancellation/close.
    conversation._current_callback = callback
    optional = conversation._create_optional_args(
        max_output_tokens=budget,
        repetition_penalty_config=litert_lm.RepetitionPenaltyConfig(
            repetition_penalty=1.05
        ),
    )
    try:
        status = lib.litert_lm_conversation_send_message_stream(
            conversation._ptr,
            json.dumps(message, ensure_ascii=False),
            "{}",
            optional,
            callback,
            None,
        )
        if status != 0:
            raise RuntimeError("Tool generation stream failed to start")
        if on_started is not None:
            on_started(conversation)
        result: dict[str, Any] = {}
        while True:
            raw, final, error = pending.get()
            if error:
                raise RuntimeError("Tool generation stream failed: " + error)
            if raw:
                try:
                    chunk = json.loads(raw)
                except json.JSONDecodeError:
                    chunk = {
                        "role": "assistant",
                        "content": [{"type": "text", "text": raw}],
                    }
                merge_stream_message(result, chunk)
                emit("delta", chunk)
            if final:
                return result or {"role": "assistant", "content": []}
    finally:
        conversation._delete_optional_args(optional)


def native_stop_tokens_supported(engine):
    """Both layers must configure the real SessionConfig before its copy."""
    return "stop_token_ids" in inspect.signature(
        engine.create_conversation
    ).parameters and hasattr(
        engine._lib, "litert_lm_session_config_add_stop_token_sequence"
    )


def normalize_stop_token_ids(value):
    if not isinstance(value, list):
        raise ValueError("Stop token sequences must be an array")
    sequences = []
    for sequence in value:
        if not isinstance(sequence, list):
            raise ValueError("Stop token sequence must be an array")
        if any(
            type(token) is not int or not -(1 << 31) <= token < (1 << 31)
            for token in sequence
        ):
            raise ValueError("Stop token IDs must be signed 32-bit integers")
        if sequence:
            sequences.append(sequence.copy())
    return sequences


def create_configured_conversation(engine, config):
    if config.get("stop_token_ids") and not native_stop_tokens_supported(engine):
        raise RuntimeError("LiteRT-LM runtime lacks native stop-token sequence support")
    return engine.create_conversation(**config)


def run_tool_conversation(
    engine,
    litert_lm,
    prompt,
    definitions,
    budget,
    *,
    emit=None,
    read_control=None,
    lease=None,
    on_stream_started=None,
):
    emit = emit or (
        lambda kind, value: print(
            kind + " " + json.dumps(value, ensure_ascii=False), flush=True
        )
    )
    read_control = read_control or sys.stdin.readline
    lease = lease or (
        lambda key, eligible, config: create_configured_conversation(engine, config)
    )
    system = "Follow the requested task faithfully. Do not invent facts."
    delegate_tool_detection = False
    messages = []
    stop_token_ids = []
    use_default_output_limit = False
    plain_conversation = (
        isinstance(definitions, dict) and definitions.get("tools") == []
    )
    if isinstance(definitions, dict):
        stop_token_ids = normalize_stop_token_ids(definitions.get("stop_token_ids", []))
        use_default_output_limit = definitions.get("use_default_output_limit", False)
        if not isinstance(use_default_output_limit, bool):
            raise ValueError("Default output limit flag must be a boolean")
        if use_default_output_limit and not plain_conversation:
            raise ValueError("Default output limit requires a plain conversation")
        messages = definitions.get("messages", [])
        if not isinstance(messages, list) or any(
            not isinstance(message, dict)
            or "content" not in message
            or message.get("role") not in ("user", "assistant")
            for message in messages
        ):
            raise ValueError("Invalid conversation history messages")
        delegate_tool_detection = definitions.get("delegate_tool_detection", False)
        if not isinstance(delegate_tool_detection, bool):
            raise ValueError("Tool detection delegation must be a boolean")
        system = definitions["system_message"]
        definitions = definitions["tools"]
        if not isinstance(system, str):
            raise ValueError("Tool system message must be a string")
    if not isinstance(definitions, list) or (
        not definitions and not plain_conversation
    ):
        raise ValueError("Tool definitions must be a nonempty array")

    ToolBase: Any = litert_lm.Tool

    class DelegatedTool(ToolBase):
        def __init__(self, definition):
            if not isinstance(definition, dict):
                raise ValueError("Tool definition must be an object")
            self.definition = (
                definition
                if "function" in definition
                else {"type": "function", "function": definition}
            )

        def get_tool_description(self):
            return self.definition

        def execute(self, param):
            raise RuntimeError("Tool execution belongs to the application service")

    delegated = [DelegatedTool(d) for d in definitions]
    encoded_tools = json.dumps(
        [tool.get_tool_description() for tool in delegated],
        ensure_ascii=False,
        separators=(",", ":"),
    )
    if (
        len(engine.tokenize(prompt))
        + len(engine.tokenize(system))
        + len(engine.tokenize(encoded_tools))
        + (
            len(
                engine.tokenize(
                    json.dumps(messages, ensure_ascii=False, separators=(",", ":"))
                )
            )
            if messages
            else 0
        )
        > 4096
    ):
        raise ValueError("Conversation input exceeds the 4096-token context")

    conversation_config = dict(
        system_message=system,
        messages=messages or None,
        tools=delegated,
        automatic_tool_calling=False,
        sampler_config=litert_lm.SamplerConfig(
            top_k=40, top_p=0.9, temperature=0.4, seed=0
        ),
        thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
        filter_channel_content_from_kv_cache=True,
        enable_speculative_decoding=True,
        max_output_tokens=budget,
    )
    if use_default_output_limit:
        conversation_config.pop("max_output_tokens")
    if stop_token_ids:
        if not native_stop_tokens_supported(engine):
            raise RuntimeError(
                "LiteRT-LM runtime lacks native stop-token sequence support"
            )
        conversation_config["stop_token_ids"] = stop_token_ids
    with lease(
        json.dumps([system, encoded_tools, budget], ensure_ascii=False),
        bool(definitions)
        and not messages
        and not stop_token_ids
        and not use_default_output_limit,
        conversation_config,
    ) as conversation:
        message = {"role": "user", "content": prompt}
        for turn in range(20):
            # The raw C callback preserves verbatim string tool arguments;
            # Python Message.from_json would JSON-decode those arguments.
            value = stream_tool_response(
                conversation,
                litert_lm,
                message,
                None if use_default_output_limit else budget,
                emit,
                on_stream_started,
            )
            if not isinstance(value, dict):
                raise ValueError("Invalid tool generation response")
            if delegate_tool_detection:
                emit("model", value)
                line = read_control()
                if not line:
                    raise RuntimeError("Tool conversation owner disconnected")
                control = json.loads(line)
                if control.get("finish", False):
                    result = (
                        {"error": control["error"]} if "error" in control else value
                    )
                    emit("answer", result)
                    return
                if turn == 19:
                    emit(
                        "answer",
                        {"error": "Max turns reached after tool call detection"},
                    )
                    return
                message = control["message"]
                if not isinstance(message, dict) or message.get("role") != "user":
                    raise ValueError("Invalid tool response message")
                continue
            calls = value.get("tool_calls")
            if not calls:
                emit("answer", value)
                return
            if not isinstance(calls, list):
                raise ValueError("Invalid tool calls")
            if turn == 19:
                emit("answer", {"error": "Max turns reached after tool call detection"})
                return
            emit("tool", calls)
            line = read_control()
            if not line:
                raise RuntimeError("Tool conversation owner disconnected")
            message = json.loads(line)
            if not isinstance(message, dict) or message.get("role") != "user":
                raise ValueError("Invalid tool response message")


class RequestCancelled(RuntimeError):
    pass


class ConversationBase:
    """One unmodified empty-history base, isolated from every generated turn."""

    def __init__(self, engine, litert_lm):
        self.engine, self.api = engine, litert_lm
        self.base = None
        self.key = None

    def close(self):
        if self.base is not None:
            self.base.close()
            self.base, self.key = None, None

    def acquire(self, key, eligible, config):
        if not eligible:
            return create_configured_conversation(self.engine, config)
        if self.base is None or key != self.key:
            # Create before replacing so a failed creation preserves the base.
            replacement = create_configured_conversation(self.engine, config)
            self.close()
            self.base, self.key = replacement, key
        lib = self.base._lib
        clone = lib.litert_lm_conversation_clone
        # 0.18's Python FFI omits this public C entry point. In particular the
        # default ctypes int return type would truncate the conversation pointer.
        clone.argtypes = [ctypes.c_void_p]
        clone.restype = ctypes.c_void_p
        # The original catches a failed base clone and uses the independently
        # initialized request conversation. Keep the untouched base for retry.
        try:
            pointer = clone(self.base._ptr)
        except Exception:
            return create_configured_conversation(self.engine, config)
        if not pointer:
            return create_configured_conversation(self.engine, config)
        from litert_lm.conversation import Conversation

        return Conversation(
            lib, pointer, engine=self.engine, automatic_tool_calling=False
        )


class PersistentWorker:
    """Serial requests, with a sole input owner able to cancel native decoding."""

    def __init__(self, engine, api, input_stream, output_stream, cache=None):
        self.engine, self.api = engine, api
        self.input, self.output = input_stream, output_stream
        self.cache = cache or ConversationBase(engine, api)
        self.lock = threading.RLock()
        self.output_lock = threading.Lock()
        self.pending: queue.Queue[Any] = queue.Queue()
        self.current = None
        self.closed = False
        self.last_token = 0

    def write(self, line):
        with self.output_lock:
            self.output.write(line + "\n")
            self.output.flush()

    def cancel_locked(self):
        request = self.current
        if request is None:
            return
        request["cancelled"] = True
        request["controls"].put(None)
        conversation = request["conversation"]
        if conversation is not None:
            conversation._lib.litert_lm_conversation_cancel_process(conversation._ptr)

    def read_input(self):
        try:
            for line in self.input:
                if line.strip() == "shutdown":
                    break
                fields = line.rstrip("\n").split(" ", 2)
                if (
                    len(fields) < 2
                    or not fields[1].isascii()
                    or not fields[1].isdigit()
                ):
                    continue
                command, token = fields[0], int(fields[1])
                with self.lock:
                    if command == "generate":
                        if (
                            token <= self.last_token
                            or self.current is not None
                            or len(fields) != 3
                        ):
                            # Never emit a second terminal frame for an active or
                            # stale token. The host owns monotonically increasing IDs.
                            continue
                        request = dict(
                            token=token,
                            payload=fields[2],
                            controls=queue.Queue(),
                            cancelled=False,
                            conversation=None,
                        )
                        self.last_token, self.current = token, request
                        self.pending.put(request)
                    elif self.current is not None and token == self.current["token"]:
                        if command == "cancel":
                            self.cancel_locked()
                        elif (
                            command == "reply"
                            and len(fields) == 3
                            and not self.current["cancelled"]
                        ):
                            self.current["controls"].put(fields[2])
        finally:
            with self.lock:
                self.closed = True
                self.cancel_locked()
            self.pending.put(None)

    def serve(self):
        self.write("ready 1")
        reader = threading.Thread(
            target=self.read_input, name="inference-input", daemon=True
        )
        reader.start()
        try:
            while True:
                request = self.pending.get()
                if request is None:
                    return
                token = request["token"]

                def check_cancelled(request=request):
                    with self.lock:
                        if request["cancelled"]:
                            raise RequestCancelled("Request cancelled")

                def emit(kind, value, token=token):
                    check_cancelled()
                    self.write(
                        str(token)
                        + " "
                        + kind
                        + " "
                        + json.dumps(value, ensure_ascii=False)
                    )

                def control(request=request):
                    check_cancelled()
                    value = request["controls"].get()
                    check_cancelled()
                    if value is None:
                        raise RequestCancelled("Request cancelled")
                    return value

                @contextmanager
                def lease(key, eligible, config, request=request):
                    check_cancelled()
                    conversation = self.cache.acquire(key, eligible, config)
                    try:
                        with self.lock:
                            request["conversation"] = conversation
                            check_cancelled()
                        yield conversation
                    finally:
                        # Cancel holds this same lock while using the pointer.
                        # Clear before delete, then terminal frames follow close.
                        with self.lock:
                            request["conversation"] = None
                        conversation.close()

                def stream_started(conversation, request=request):
                    # Cancel may arrive between pointer registration and the
                    # native start; repeat it once there is work to interrupt.
                    with self.lock:
                        if request["cancelled"]:
                            conversation._lib.litert_lm_conversation_cancel_process(
                                conversation._ptr
                            )

                status = "completed"
                try:
                    check_cancelled()
                    value = json.loads(request["payload"])
                    if not isinstance(value, dict) or not isinstance(
                        value.get("prompt"), str
                    ):
                        raise ValueError("Invalid generation request")
                    budget = value.get("max_output_tokens", 256)
                    if not valid_output_budget(budget, value.get("tools")):
                        raise ValueError("Output budget must be between 1 and 3072")
                    run_tool_conversation(
                        self.engine,
                        self.api,
                        value["prompt"],
                        value["tools"],
                        budget,
                        emit=emit,
                        read_control=control,
                        lease=lease,
                        on_stream_started=stream_started,
                    )
                    check_cancelled()
                except Exception as error:
                    with self.lock:
                        status = "cancelled" if request["cancelled"] else "failed"
                    if status == "failed":
                        self.write(
                            str(token)
                            + " error "
                            + json.dumps(str(error), ensure_ascii=False)
                        )
                with self.lock:
                    # Serialize terminal publication and accepting the next ID.
                    if request["cancelled"]:
                        status = "cancelled"
                    self.current = None
                    self.write(str(token) + " done " + status)
        finally:
            self.cache.close()


def run_query_detector(engine, prompt):
    """Raw TextCache equivalent for the dedicated model, with an empty base.

    LiteRT 0.18 rejects TOP_K during decode. TOP_P with k=1 and p=1 keeps
    the same single candidate as the recovered TOP_K k=1 policy. The caller
    must load the dedicated model; this does not select chat weights.
    """
    from contextlib import ExitStack
    import ctypes

    lib = engine._lib
    with ExitStack() as cleanup:

        def owned(pointer, destroy):
            if not pointer:
                raise RuntimeError("Raw detector LiteRT operation failed")
            cleanup.callback(destroy, pointer)
            return pointer

        config = owned(
            lib.litert_lm_session_config_create(), lib.litert_lm_session_config_delete
        )
        lib.litert_lm_session_config_set_apply_prompt_template(config, False)
        lib.litert_lm_session_config_set_max_output_tokens(config, 512)
        sampler = owned(
            lib.litert_lm_sampler_params_create(2), lib.litert_lm_sampler_params_delete
        )
        lib.litert_lm_sampler_params_set_top_k(sampler, 1)
        lib.litert_lm_sampler_params_set_top_p(sampler, 1.0)
        lib.litert_lm_sampler_params_set_temperature(sampler, 0.3)
        lib.litert_lm_session_config_set_sampler_params(config, sampler)
        session = owned(
            lib.litert_lm_engine_create_session(engine._engine_ptr, config),
            lib.litert_lm_session_delete,
        )
        # CTextCacheInput strings are NUL-terminated in the original native API.
        encoded = prompt.split("\0", 1)[0].encode("utf-8")
        data = owned(
            lib.litert_lm_input_data_create(0, encoded, len(encoded)),
            lib.litert_lm_input_data_delete,
        )
        inputs = (ctypes.c_void_p * 1)(data)
        if lib.litert_lm_session_run_prefill(session, inputs, 1) != 0:
            raise RuntimeError("Raw detector prefill failed")
        response = owned(
            lib.litert_lm_session_run_decode(session), lib.litert_lm_responses_delete
        )
        if lib.litert_lm_responses_get_num_candidates(response) < 1:
            raise RuntimeError("Raw detector returned no candidates")
        text = lib.litert_lm_responses_get_response_text_at(response, 0)
        if text is None:
            raise RuntimeError("Raw detector returned a null candidate")
        sys.stdout.write(text.decode("utf-8"))
        sys.stdout.flush()


def _startup_warning(message):
    print(message, file=sys.stderr, flush=True)


def delete_model_cache_file(path, *, sleep=None, warn=None):
    """Retry a single cache-file unlink; never remove a directory tree."""
    sleep = sleep or time.sleep
    warn = warn or _startup_warning
    path = Path(path)
    for attempt in range(1, 6):
        try:
            if not path.exists():
                return True
            path.unlink()
            return True
        except Exception as error:
            if attempt == 5:
                warn(f"Cannot delete model cache file {path}: {error}")
                return False
            sleep(attempt / 10)


def clear_model_cache(model, cache, *, delete=None, warn=None):
    """Map the recovered support-cache scope to this runner's owned cache.

    The adjacent scan uses substring tests, not suffix tests. A symlink to a
    regular file is unlinked at its own path, without deleting its target.
    """
    model, cache = Path(model), Path(cache)
    delete = delete or delete_model_cache_file
    warn = warn or _startup_warning

    def matches(path):
        return path.name.startswith(model.name) or path.name.startswith(model.stem)

    try:
        if cache.exists():
            for path in cache.iterdir():
                if path != model and path.is_file() and matches(path):
                    delete(path)
        for path in model.parent.iterdir():
            if (
                path != model
                and path.is_file()
                and matches(path)
                and ("_mldrift_" in path.name or ".xnnpack_cache" in path.name)
            ):
                delete(path)
    except OSError as error:
        warn(f"Cannot clear model cache for {model}: {error}")


def generation_model_config(model_type):
    canonical = {8: 15, 10: 15, 9: 14, 12: 16}.get(model_type, model_type)
    if canonical in (14, 15):
        return dict(vision_backend="gpu", audio_backend="cpu", visual_tokens=280)
    if canonical == 16:
        return dict(vision_backend="gpu", audio_backend="gpu", visual_tokens=560)
    return dict(vision_backend=None, audio_backend="cpu", visual_tokens=0)


def configured_engine_api(api):
    """Bind the pinned public C settings omitted by the 0.18 Python wrapper.

    Reuse its conversation/tokenizer/close implementation. Engine creation owns
    every settings handle and retains a partial native engine for recovery.
    No SDK globals or loaded-library functions are replaced.
    """
    import types
    from litert_lm import interfaces
    from litert_lm._ffi import _get_lib

    EngineBase: Any = api.Engine

    class ConfiguredEngine(EngineBase):
        def __init__(self, model_path, *, visual_tokens=None, **settings):
            interfaces.AbstractEngine.__init__(self, model_path=model_path, **settings)
            self._lib = _get_lib()
            self._engine_ptr = None
            lib = self._lib
            native = lib.litert_lm_engine_settings_create(
                model_path,
                self.backend.get_name(),
                self.vision_backend.get_name() if self.vision_backend else None,
                self.audio_backend.get_name() if self.audio_backend else None,
            )
            if not native:
                raise RuntimeError("Cannot create generation settings")
            try:
                if self.max_num_tokens is not None:
                    lib.litert_lm_engine_settings_set_max_num_tokens(
                        native, self.max_num_tokens
                    )
                if (
                    isinstance(self.backend, interfaces.CPU)
                    and self.backend.thread_count is not None
                ):
                    lib.litert_lm_engine_settings_set_num_threads(
                        native, self.backend.thread_count
                    )
                if (
                    isinstance(self.audio_backend, interfaces.CPU)
                    and self.audio_backend.thread_count is not None
                ):
                    lib.litert_lm_engine_settings_set_audio_num_threads(
                        native, self.audio_backend.thread_count
                    )
                if self.cache_dir is not None:
                    lib.litert_lm_engine_settings_set_cache_dir(native, self.cache_dir)
                if self.enable_speculative_decoding is not None:
                    lib.litert_lm_engine_settings_set_enable_speculative_decoding(
                        native, self.enable_speculative_decoding
                    )
                if visual_tokens is not None:
                    setter = (
                        lib.litert_lm_engine_settings_set_max_vision_tokens_per_image
                    )
                    setter.argtypes = [ctypes.c_void_p, ctypes.c_int]
                    setter.restype = None
                    setter(native, visual_tokens)
                self._engine_ptr = lib.litert_lm_engine_create(native)
                if not self._engine_ptr:
                    raise RuntimeError("Cannot initialize generation model")
            finally:
                lib.litert_lm_engine_settings_delete(native)

    return types.SimpleNamespace(Engine=ConfiguredEngine)


def _engine_startup_attempt(api, model, settings):
    # Keep the partial instance owned if __init__ raises. Calling the normal
    # constructor would lose that reference before the recovered shutdown step.
    engine = api.Engine.__new__(api.Engine)
    try:
        api.Engine.__init__(engine, str(model), **settings)
    except Exception as error:
        return engine, error
    return engine, None


@contextmanager
def initialize_generation_engine(
    api, model, cache, *, clear_cache=None, warn=None, **settings
):
    """Retry identical initialization, then disable vision on its second error."""
    clear_cache = clear_cache or clear_model_cache
    warn = warn or _startup_warning
    engine, error = _engine_startup_attempt(api, model, settings)
    if error is not None:
        warn(f"Model initialization failed; clearing its cache before retry: {error}")
        try:
            clear_cache(model, cache)
            Path(cache).mkdir(mode=0o700, parents=True, exist_ok=True)
        finally:
            engine.close()
        engine, error = _engine_startup_attempt(api, model, settings)
        if error is not None:
            engine.close()
            if settings.get("vision_backend") is None:
                raise error
            warn("Vision initialization failed twice; retrying with vision disabled")
            settings = dict(settings, vision_backend=None)
            settings.pop("visual_tokens", None)
            engine, error = _engine_startup_attempt(api, model, settings)
            if error is not None:
                engine.close()
                raise error
    try:
        yield engine
    finally:
        engine.close()


def run(args):
    if importlib.metadata.version("litert-lm") != "0.18.0":
        raise RuntimeError("This runner requires litert-lm==0.18.0")
    import litert_lm

    if args.check:
        return

    model = Path(args.model).resolve(strict=True)
    if not model.is_file():
        raise ValueError("Model must be a local file")
    cache = (
        Path(
            os.environ.get(
                "FORESIGHT_LITERT_CACHE", str(model.parent / ".litert-cache")
            )
        )
        / args.backend
    )
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    backend = (
        litert_lm.Backend.GPU()
        if args.backend == "gpu"
        else litert_lm.Backend.CPU(thread_count=4)
    )
    settings = dict(
        backend=backend,
        audio_backend=litert_lm.Backend.CPU(thread_count=4),
        max_num_tokens=512 if args.query_detector else 4096,
        cache_dir=str(cache),
    )
    config = generation_model_config(
        0 if args.query_detector else getattr(args, "model_type", 0)
    )
    engine_api = litert_lm
    if config["vision_backend"] is not None:
        settings.update(
            vision_backend=litert_lm.Backend.GPU(),
            enable_speculative_decoding=True,
            visual_tokens=config["visual_tokens"],
            audio_backend=(
                litert_lm.Backend.GPU()
                if config["audio_backend"] == "gpu"
                else litert_lm.Backend.CPU(thread_count=4)
            ),
        )
        engine_api = configured_engine_api(litert_lm)
    startup = (
        litert_lm.Engine(str(model), **settings)
        if args.query_detector
        else initialize_generation_engine(engine_api, model, cache, **settings)
    )
    with startup as engine:
        if args.probe:
            print(
                json.dumps(
                    {
                        "worker_protocol": 1,
                        "native_stop_token_sequences": native_stop_tokens_supported(
                            engine
                        ),
                    }
                ),
                flush=True,
            )
            return
        if args.serve:
            PersistentWorker(engine, litert_lm, sys.stdin, sys.stdout).serve()
            return
        prompt = args.prompt
        if prompt is None:
            line = sys.stdin.readline()
            try:
                payload = json.loads(line) if line else None
            except json.JSONDecodeError:
                payload = None
            prompt = payload.get("prompt") if isinstance(payload, dict) else None
            if not isinstance(prompt, str):
                raise ValueError("A prompt is required")
        if args.query_detector:
            run_query_detector(engine, prompt)
            return
        if args.tools:
            if args.json_schema:
                raise ValueError("Tools cannot be combined with a response schema")
            run_tool_conversation(
                engine,
                litert_lm,
                prompt,
                json.loads(args.tools),
                args.max_output_tokens,
            )
            return
        schema = None
        if args.json_schema:
            schema = json.loads(args.json_schema)
            if not isinstance(schema, dict):
                raise ValueError("JSON schema must be an object")
            request = schema.pop("x-foresight-grounded-request", None)
            if request is not None:
                # -I deliberately omits script directories from sys.path.
                # Load only the shipped sibling, never a cwd/user module.
                spec = importlib.util.spec_from_file_location(
                    "foresight_grounded",
                    Path(__file__).with_name("grounded_generation.py"),
                )
                if spec is None or spec.loader is None:
                    raise RuntimeError("Packaged module has no loader")
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                result = module.grounded_answer(
                    engine, litert_lm, request, args.max_output_tokens
                )
                sys.stdout.write(json.dumps(result, ensure_ascii=False))
                sys.stdout.flush()
                return
            prompt += "\nReturn exactly one JSON object with the requested answer and source IDs, without markdown or explanation outside the object."
        if len(engine.tokenize(prompt)) + args.max_output_tokens + 256 > 4096:
            raise ValueError("Prompt and output reserve exceed the 4096-token context")
        with engine.create_conversation(
            system_message="Follow the requested task faithfully. Do not invent facts.",
            automatic_tool_calling=False,
            sampler_config=litert_lm.SamplerConfig(
                top_k=40, top_p=0.9, temperature=0.4, seed=0
            ),
            thinking_config=litert_lm.ThinkingConfig(enable_thinking=False),
            filter_channel_content_from_kv_cache=True,
            constrained_decoding_config=litert_lm.ConstrainedDecodingConfig(
                enable=schema is not None,
                provider=litert_lm.LiteRtLmConstraintProviderType.LL_GUIDANCE
                if schema is not None
                else None,
            ),
            enable_speculative_decoding=schema is None,
            max_output_tokens=args.max_output_tokens,
        ) as conversation:
            text = ""
            for chunk in conversation.send_message_async(
                prompt,
                max_output_tokens=args.max_output_tokens,
                response_format=litert_lm.ResponseFormat.json(schema)
                if schema is not None
                else None,
                repetition_penalty_config=litert_lm.RepetitionPenaltyConfig(
                    repetition_penalty=1.05
                ),
            ):
                if chunk.tool_calls:
                    raise RuntimeError("Model emitted an unsupported tool call")
                part = str(chunk)
                text += part
                if len(text) >= 128 and text[-128:].isspace():
                    raise RuntimeError("Generation entered a whitespace loop")
                sys.stdout.write(part)
                sys.stdout.flush()
            # This API does not expose a reliable finish reason. Conservatively
            # reject output near the token budget instead of publishing it as
            # a complete note. Structured callers also require complete JSON.
            if len(engine.tokenize(text)) >= max(1, args.max_output_tokens - 16):
                raise RuntimeError(
                    "Generation reached the output budget; retry with more tokens"
                )
            if not text.strip():
                raise RuntimeError("Generation returned empty text")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model")
    parser.add_argument(
        "--model-type",
        type=int,
        choices=range(18),
        default=0,
        help="Internal distribution model type; preserves model-specific startup defaults",
    )
    parser.add_argument(
        "--backend",
        choices=("cpu", "gpu"),
        default=os.environ.get("FORESIGHT_LITERT_BACKEND", "cpu"),
    )
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--query-detector", action="store_true")
    parser.add_argument("--prompt")
    parser.add_argument("--json-schema")
    parser.add_argument("--tools")
    parser.add_argument("--max-output-tokens", type=int, default=256)
    args = parser.parse_args()
    if args.query_detector:
        if args.tools or args.json_schema or args.serve:
            parser.error("Raw query detection cannot use tools or a response schema")
        # The original dedicated GEMMA4_200M asset declares backend=gpu.
        args.backend = "gpu"
    if args.backend not in ("cpu", "gpu"):
        parser.error("FORESIGHT_LITERT_BACKEND must be cpu or gpu")
    if not args.check and not args.model:
        parser.error("a local model file is required")
    try:
        definitions = json.loads(args.tools) if args.tools else None
    except json.JSONDecodeError:
        parser.error("invalid conversation configuration")
    if not valid_output_budget(args.max_output_tokens, definitions):
        parser.error(
            "output budget must be between 1 and 3072, or the explicit plain native default"
        )
    # Native GPU drivers may write to fd 1. Keep streamed text/JSON on a
    # separate descriptor so driver diagnostics cannot become answer content.
    protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    sys.stdout = protocol
    try:
        run(args)
    except Exception as error:
        print(
            f"LiteRT-LM runner failed: {error}",
            file=sys.stdout if args.probe else sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
