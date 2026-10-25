import 'rpc_error.dart';
import 'desktop_connection.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'platform_services.dart';
import 'native_lifetime.dart';
import 'package:ffi/ffi.dart';
import 'reference_tools.dart';
import 'reference_tool_parser.dart';
import 'runtime_execution_policy.dart';

/// Packaged installations always use their bundled native worker, including
/// profiles that still contain the former Python runner path.
String liteRtRunner(String registered) =>
    runtimeConfiguration['FORESIGHT_LITERT_RUNNER'] ?? registered;

typedef CreateNative = Uint64 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef CreateDart = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// The returned runtime owns its mapping and native handles. No borrowed native
/// pointer crosses an isolate or is reconstructed from an integer address.
Future<NativeRuntime> probeNativeModel(
  String libraryPath,
  String runtime,
  String model, {
  String backend = 'llama_cpp',
  int modelType = 0,
}) async {
  runtime = requireInstalledRuntime(
    backend == 'litert_lm' ? liteRtRunner(runtime) : runtime,
  );
  final candidate = NativeRuntime(libraryPath)..modelType = modelType;
  try {
    await candidate.load(runtime, model, backend: backend);
    return candidate;
  } catch (error, stack) {
    candidate.close();
    try {
      await candidate.closed;
    } catch (_) {}
    Error.throwWithStackTrace(error, stack);
  }
}

class _GenerationRequest {
  final String id;
  final int handle;
  final int epoch;
  bool released = false;
  Future<void>? closed;
  bool cancelled = false;
  _GenerationRequest(this.id, this.handle, this.epoch);
}

class NativeRuntime implements GenerationStatus {
  late final _nativeFsEngineCreate = lib
      .lookupFunction<
        Uint64 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Int32),
        int Function(Pointer<Utf8>, Pointer<Utf8>, int, int)
      >('fs_owned_engine_create');
  late final _nativeFsEngineState = lib
      .lookupFunction<
        Pointer<Utf8> Function(Uint64),
        Pointer<Utf8> Function(int)
      >('fs_owned_engine_state');
  late final _nativeFsStringFree = lib
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('fs_string_free');
  late final _nativeFsConversationCreate = lib
      .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
        'fs_owned_conversation_create',
      );
  late final _nativeFsGenerateTools = lib
      .lookupFunction<
        Int32 Function(
          Uint64,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Int32,
        ),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)
      >('fs_owned_generate_tools');
  late final _nativeFsGenerateOptions = lib
      .lookupFunction<
        Int32 Function(
          Uint64,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Pointer<Utf8>,
          Int32,
        ),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)
      >('fs_owned_generate_options');
  late final _nativeFsEventPoll = lib
      .lookupFunction<
        Pointer<Utf8> Function(Uint64, Int32),
        Pointer<Utf8> Function(int, int)
      >('fs_owned_event_poll');
  late final _nativeFsGenerationToolReply = lib
      .lookupFunction<
        Int32 Function(Uint64, Pointer<Utf8>, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>)
      >('fs_owned_generation_tool_reply');
  late final _nativeFsGenerationCancel = lib
      .lookupFunction<Int32 Function(Uint64), int Function(int)>(
        'fs_owned_generation_cancel',
      );

  late final NativeLibrary _bindings;
  DynamicLibrary get lib => _bindings.library;
  NativeLifetime get _lifetime => _bindings.lifetime;
  bool get restartRequired => _bindings.restartRequired;
  void checkAvailable() => _bindings.checkAvailable();
  int _engine = 0, _conversation = 0;
  int get engine => _engine;
  int get conversation => _conversation;
  Future<void>? _closed;
  Future<void> get closed => _closed ?? Future<void>.value();
  String template = 'raw';
  int modelType = 0;
  final String libraryPath;
  int _epoch = 0;
  _GenerationRequest? _active;
  final _callbacks = <Future<void>>{};
  void Function()? onOwnershipChanged;
  Object? _observerFailure;
  StackTrace? _observerStack;
  void _notifyOwnership() {
    try {
      onOwnershipChanged?.call();
    } catch (error, stack) {
      _observerFailure ??= error;
      _observerStack ??= stack;
    }
  }

  Future<T> _ownCallback<T>(
    _GenerationRequest owner,
    Future<T> Function() run,
  ) {
    final settled = Completer<void>();
    _callbacks.add(settled.future);
    _notifyOwnership();
    // Publish ownership before invoking user code, which may close the runtime
    // synchronously before returning its pending Future.
    final work = Future<T>.sync(() {
      if (owner.released ||
          owner.cancelled ||
          !identical(_active, owner) ||
          owner.epoch != _epoch) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Tool request is no longer current',
        );
      }
      return run();
    });
    unawaited(
      work.then<void>(
        (_) => settled.complete(),
        onError: (Object _, StackTrace _) => settled.complete(),
      ),
    );
    unawaited(
      settled.future.then<void>((_) {
        _callbacks.remove(settled.future);
        _notifyOwnership();
      }),
    );
    return work;
  }

  @override
  bool get generating => _active != null || _callbacks.isNotEmpty;
  bool get loaded => engine != 0 && conversation != 0;
  String _phase = 'unconfigured', _lastError = '';
  NativeRuntime(String path) : libraryPath = path {
    _bindings = NativeLibrary(DynamicLibrary.open(path));
  }
  @override
  Map<String, dynamic> get effectiveState {
    if (restartRequired) {
      return {
        'state': 'failed',
        'restart_required': true,
        'error': 'Native ownership is unconfirmed; restart the service',
      };
    }
    if (engine == 0) return {'state': _phase, 'error': _lastError};
    final p = _nativeFsEngineState(engine);
    if (p == nullptr) return {'state': 'failed'};
    try {
      return jsonDecode(p.toDartString()) as Map<String, dynamic>;
    } finally {
      _nativeFsStringFree(p);
    }
  }

  void _requireEpoch(int epoch) {
    if (epoch != _epoch) {
      throw RpcError(
        RpcErrorCode.cancelled,
        'Model load cancelled before adoption',
      );
    }
  }

  Future<void> load(
    String runtime,
    String model, {
    String backend = 'llama_cpp',
  }) async {
    if (backend == 'litert_lm') runtime = liteRtRunner(runtime);
    runtime = requireInstalledRuntime(runtime);
    if (!['llama_cpp', 'litert_lm'].contains(backend)) {
      throw ArgumentError.value(backend);
    }
    final epoch = _epoch + 1;
    close();
    _requireEpoch(epoch);
    _phase = 'loading';
    _lastError = '';
    template = backend == 'llama_cpp' && model.toLowerCase().contains('qwen')
        ? 'chatml'
        : 'raw';
    try {
      await closed;
      _requireEpoch(epoch);
      _closed = null;
      final lifetime = _lifetime;
      lifetime.ensureAdmission();
      final a = runtime.toNativeUtf8(), b = model.toNativeUtf8();
      try {
        _engine = _nativeFsEngineCreate(
          a,
          b,
          backend == 'llama_cpp' ? 0 : 1,
          modelType,
        );
      } finally {
        calloc.free(a);
        calloc.free(b);
      }
      if (engine == 0) {
        throw StateError('Native model initialization failed');
      }
      final result = await lifetime.request('fs_engine_probe_async', engine);
      _requireEpoch(epoch);
      if (result != 1) {
        throw StateError(
          'Native model load/inference probe failed: ${effectiveState['error'] ?? ''}',
        );
      }
      lifetime.ensureAdmission();
      _conversation = _nativeFsConversationCreate(engine);
      if (conversation == 0) {
        throw StateError('Native conversation initialization failed');
      }
      _phase = 'ready';
    } catch (error, stack) {
      if (epoch == _epoch) {
        close();
        final closingEpoch = _epoch;
        try {
          await closed;
        } catch (_) {}
        if (closingEpoch == _epoch) {
          _phase = 'failed';
          _lastError = error.toString();
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt =
        'Follow the requested task faithfully. Do not invent facts.',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) => _generate(
    id,
    prompt,
    systemPrompt: systemPrompt,
    responseSchema: responseSchema,
    timeout: timeout,
    maxOutputTokens: maxOutputTokens,
  );

  /// Local meeting brief with distinct system/user messages on LiteRT. Legacy
  /// text backends keep their existing framing; no model-directed tools exist.
  Stream<Map<String, dynamic>> generateSummary(
    String id,
    String prompt, {
    required String systemPrompt,
    int maxOutputTokens = 1024,
  }) => effectiveState['tools'] == true
      ? _generate(
          id,
          prompt,
          systemPrompt: systemPrompt,
          tools: const [],
          toolDispatcher: ReferenceToolDispatcher({}),
          plainConversation: true,
          maxOutputTokens: maxOutputTokens,
          timeout: const Duration(seconds: 120),
        )
      : generate(
          id,
          prompt,
          systemPrompt: systemPrompt,
          maxOutputTokens: maxOutputTokens,
          timeout: const Duration(seconds: 120),
        );

  Stream<Map<String, dynamic>> generateWithTools(
    String id,
    String prompt, {
    required List<Map<String, dynamic>> tools,
    required ReferenceToolDispatcher dispatcher,
    List<Map<String, dynamic>> messages = const [],
    String systemPrompt =
        'Follow the requested task faithfully. Do not invent facts.',
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) => _generate(
    id,
    prompt,
    tools: tools,
    toolDispatcher: dispatcher,
    initialMessages: messages,
    systemPrompt: systemPrompt,
    timeout: timeout,
    maxOutputTokens: maxOutputTokens,
  );

  /// Web answers consume already-fetched results; model text has no tool path.
  Stream<Map<String, dynamic>> generateWebAnswer(
    String id,
    String prompt, {
    List<Map<String, dynamic>> messages = const [],
    required String systemPrompt,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 1024,
  }) => _generate(
    id,
    prompt,
    tools: const [],
    toolDispatcher: ReferenceToolDispatcher({}),
    initialMessages: messages,
    plainConversation: true,
    systemPrompt: systemPrompt,
    timeout: timeout,
    maxOutputTokens: maxOutputTokens,
  );

  /// A fresh local conversation without tools or an implicit system preface.
  /// A null output limit preserves the native default. The original serialized
  /// input setting is passed through without inventing a local token limit.
  Stream<Map<String, dynamic>> generateConversation(
    String id,
    String prompt, {
    int? maxOutputTokens = 1024,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
  }) => _generate(
    id,
    prompt,
    tools: const [],
    toolDispatcher: ReferenceToolDispatcher({}),
    plainConversation: true,
    stopTokenIds: stopTokenIds,
    maxInputTokens: maxInputTokens,
    systemPrompt: '',
    maxOutputTokens: maxOutputTokens,
    timeout: timeout,
  );

  Stream<Map<String, dynamic>> _generate(
    String id,
    String prompt, {
    String systemPrompt =
        'Follow the requested task faithfully. Do not invent facts.',
    Map<String, dynamic>? responseSchema,
    List<Map<String, dynamic>>? tools,
    ReferenceToolDispatcher? toolDispatcher,
    List<Map<String, dynamic>> initialMessages = const [],
    bool plainConversation = false,
    int? maxInputTokens,
    List<List<int>> stopTokenIds = const [],
    Duration timeout = const Duration(minutes: 5),
    int? maxOutputTokens = 256,
  }) async* {
    if (engine == 0 || conversation == 0) {
      throw RpcError(RpcErrorCode.unavailable, 'Generation model unavailable');
    }
    if (generating) {
      throw RpcError(RpcErrorCode.busy, 'Generation already in progress');
    }
    if ((tools == null) != (toolDispatcher == null) ||
        (tools != null &&
            ((!plainConversation && tools.isEmpty) ||
                responseSchema != null))) {
      throw ArgumentError('Tools require a dispatcher and no response schema');
    }
    if (id.isEmpty ||
        timeout <= Duration.zero ||
        (maxOutputTokens == null
            ? !plainConversation
            : maxOutputTokens < 1 || maxOutputTokens > 3072)) {
      throw ArgumentError('A request ID and positive timeout are required');
    }
    final outputBudget = maxOutputTokens ?? 0;
    // Each request owns a conversation. Destroy joins the native worker, so
    // the done-event/active-flag race cannot leak into the next generation.
    _lifetime.ensureAdmission();
    final handle = _nativeFsConversationCreate(engine);
    if (handle == 0) throw StateError('Native conversation unavailable');
    final owner = _GenerationRequest(id, handle, _epoch);
    _active = owner;
    final clock = Stopwatch()..start();
    try {
      _notifyOwnership();
      if (owner.released ||
          !identical(_active, owner) ||
          owner.epoch != _epoch) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Generation closed before admission',
        );
      }
      // Tool conversations carry a distinct native system message below.
      if (tools == null) {
        if (template == 'chatml') {
          prompt =
              '<|im_start|>system\n$systemPrompt<|im_end|>\n'
              '<|im_start|>user\n$prompt<|im_end|>\n<|im_start|>assistant\n';
        } else {
          prompt = '$systemPrompt\n\n$prompt';
        }
      }
      final encodedSchema = tools != null
          ? jsonEncode({
              'tools': tools,
              'system_message': systemPrompt,
              'delegate_tool_detection': true,
              'messages': initialMessages,
              if (stopTokenIds.isNotEmpty) 'stop_token_ids': stopTokenIds,
              if (maxOutputTokens == null) 'use_default_output_limit': true,
              if (maxInputTokens != null) 'max_input_tokens': maxInputTokens,
            })
          : responseSchema == null
          ? null
          : jsonEncode(responseSchema);
      final a = id.toNativeUtf8(), b = prompt.toNativeUtf8();
      final schema = encodedSchema?.toNativeUtf8() ?? nullptr.cast<Utf8>();
      late int rc;
      try {
        if (owner.released ||
            owner.cancelled ||
            !identical(_active, owner) ||
            owner.epoch != _epoch) {
          throw RpcError(
            RpcErrorCode.cancelled,
            'Generation closed before admission',
          );
        }
        _lifetime.ensureAdmission();
        if (tools != null) {
          rc = _nativeFsGenerateTools(handle, a, b, schema, outputBudget);
        } else {
          rc = _nativeFsGenerateOptions(handle, a, b, schema, outputBudget);
        }
      } finally {
        calloc.free(a);
        calloc.free(b);
        if (schema != nullptr) calloc.free(schema);
      }
      if (rc != 0) throw StateError('Native generation start failed ($rc)');
      final poll = _nativeFsEventPoll;
      final free = _nativeFsStringFree;
      var modelTurns = 0;
      var streamedText = '';
      while (true) {
        // close/load may have destroyed this handle while awaiting the timer
        // or while a consumer was processing a yielded event.
        if (owner.released ||
            !identical(_active, owner) ||
            owner.epoch != _epoch) {
          throw RpcError(
            RpcErrorCode.cancelled,
            'Generation closed before completion',
          );
        }
        if (clock.elapsed >= timeout) {
          throw TimeoutException('Native generation timed out', timeout);
        }
        final p = poll(handle, 0);
        if (p == nullptr) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }
        late Map<String, dynamic> event;
        try {
          event = jsonDecode(p.toDartString()) as Map<String, dynamic>;
        } finally {
          free(p);
        }
        if (event['request_id'] != id) {
          throw StateError('Native generation returned a different request ID');
        }
        if (event['type'] == 'model_delta') {
          final chunk = jsonDecode(event['text'] as String);
          if (chunk is! Map<String, dynamic>) {
            throw FormatException('Invalid streamed model response');
          }
          final content = chunk['content'];
          final String text;
          if (content is String) {
            text = content;
          } else if (content is List) {
            text = content
                .where((part) => part is Map && part['type'] == 'text')
                .map((part) => part['text'] as String)
                .join();
          } else {
            text = '';
          }
          if (text.isNotEmpty) {
            streamedText += text;
            yield {...event, 'type': 'preview', 'text': streamedText};
          }
          continue;
        }
        if (event['type'] == 'tool_request' ||
            event['type'] == 'model_response') {
          if (toolDispatcher == null) {
            throw StateError('Unexpected tool request');
          }
          final delegated = event['type'] == 'model_response';
          final payload = jsonDecode(event['text'] as String);
          final calls = delegated
              ? plainConversation
                    ? null
                    : extractReferenceToolCalls(payload as Map<String, dynamic>)
              : payload as List<dynamic>;
          streamedText = '';
          if (delegated) modelTurns++;
          late Map<String, dynamic> message;
          if (delegated && (calls == null || calls.isEmpty)) {
            message = {'finish': true};
          } else if (delegated && modelTurns >= 20) {
            message = {
              'finish': true,
              'error': 'Max turns reached after tool call detection',
            };
          } else {
            final interrupted = Completer<Map<String, dynamic>>();
            final monitor = Timer.periodic(const Duration(milliseconds: 20), (
              _,
            ) {
              if (interrupted.isCompleted) return;
              if (owner.released ||
                  !identical(_active, owner) ||
                  owner.epoch != _epoch ||
                  owner.cancelled) {
                interrupted.completeError(
                  RpcError(
                    RpcErrorCode.cancelled,
                    'Tool request is no longer current',
                  ),
                );
              } else if (clock.elapsed >= timeout) {
                interrupted.completeError(
                  TimeoutException('Native generation timed out', timeout),
                );
              }
            });
            try {
              final reply = await Future.any([
                _ownCallback(
                  owner,
                  () => toolDispatcher.handle(calls!, maxTokens: 4096),
                ),
                interrupted.future,
              ]);
              message = delegated ? {'message': reply} : reply;
            } finally {
              monitor.cancel();
            }
          }
          if (owner.released ||
              !identical(_active, owner) ||
              owner.epoch != _epoch ||
              owner.cancelled) {
            throw RpcError(
              RpcErrorCode.cancelled,
              'Tool request is no longer current',
            );
          }
          if (clock.elapsed >= timeout) {
            throw TimeoutException('Native generation timed out', timeout);
          }
          final encodedReply = jsonEncode(message);
          final request = id.toNativeUtf8();
          final reply = encodedReply.toNativeUtf8();
          try {
            if (owner.released ||
                owner.cancelled ||
                !identical(_active, owner) ||
                owner.epoch != _epoch) {
              throw RpcError(
                RpcErrorCode.cancelled,
                'Tool request is no longer current',
              );
            }
            final result = _nativeFsGenerationToolReply(handle, request, reply);
            if (result != 0) {
              throw StateError(
                'Tool request was cancelled or already answered',
              );
            }
          } finally {
            calloc.free(request);
            calloc.free(reply);
          }
          continue;
        }
        if (event['type'] == 'tool_answer') {
          final response =
              jsonDecode(event['text'] as String) as Map<String, dynamic>;
          if (response['error'] != null) {
            throw StateError(response['error'].toString());
          }
          final content = response['content'];
          final String text;
          if (content is String) {
            text = content;
          } else if (content is List) {
            text = content
                .where((part) => part is Map && part['type'] == 'text')
                .map((part) => part['text'] as String)
                .join();
          } else {
            throw FormatException('Invalid tool answer content');
          }
          yield {...event, 'type': 'delta', 'text': text, 'response': response};
          continue;
        }
        yield event;
        if (event['type'] == 'done') break;
      }
    } finally {
      try {
        await _release(owner);
      } finally {
        if (identical(_active, owner)) _active = null;
        _notifyOwnership();
      }
    }
  }

  Future<void> _release(_GenerationRequest owner) {
    if (owner.released) return owner.closed!;
    owner.released = true;
    return owner.closed = _lifetime.retire(
      'fs_conversation_retire',
      owner.handle,
    );
  }

  /// Supplying an ID prevents a stale UI/controller from cancelling a new task.
  @override
  bool cancel({String? requestId}) {
    final owner = _active;
    if (owner == null ||
        owner.released ||
        (requestId != null && owner.id != requestId)) {
      return false;
    }
    owner.cancelled = true;
    _nativeFsGenerationCancel(owner.handle);
    return true;
  }

  /// Request-scoped actual native cleanup, including a paused stream consumer.
  /// A late continuation still observes its released identity before any FFI.
  Future<void> cancelAndDrain({String? requestId}) {
    final owner = _active;
    cancel(requestId: requestId);
    if (owner == null || (requestId != null && owner.id != requestId)) {
      return Future<void>.value();
    }
    return _release(owner).whenComplete(() {
      if (identical(_active, owner)) _active = null;
      _notifyOwnership();
    });
  }

  @override
  void close() {
    _epoch++;
    _phase = 'unconfigured';
    final previous = _closed;
    final pending = <Future<void>>[
      if (previous != null) previous,
      ..._callbacks,
    ];
    final owner = _active;
    _active = null;
    if (owner != null) pending.add(_release(owner));
    final oldConversation = conversation, oldEngine = engine;
    _conversation = 0;
    _engine = 0;
    if (owner == null &&
        oldConversation == 0 &&
        oldEngine == 0 &&
        (previous != null || _callbacks.isEmpty)) {
      return;
    }
    if (oldConversation != 0) {
      pending.add(_lifetime.retire('fs_conversation_retire', oldConversation));
    }
    if (oldEngine != 0) {
      pending.add(_lifetime.retire('fs_engine_retire', oldEngine));
    }
    if (pending.isEmpty) return;
    final completion = Future.wait(pending).then<void>((_) {
      final failure = _observerFailure;
      if (failure != null) Error.throwWithStackTrace(failure, _observerStack!);
    });
    unawaited(
      completion.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    _closed = completion;
    _notifyOwnership();
  }
}
