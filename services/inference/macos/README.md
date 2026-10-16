# Mac inference compatibility runtime

Linux uses the native LiteRT/ONNX worker in the parent directory. Its pinned
standalone runtime archives currently target Linux x86-64. Mac retains its
validated Python runtime and Metal-backed LiteRT adapters until native Apple
Silicon libraries have been integrated and tested.

`foresight-model` exposes the same `--embedding MODEL [--gpu]` entrypoint to the
helper, then selects the existing embedding adapter. CMake copies this runtime
beside the development worker; Mac packaging copies it into the application's
adapters directory and records `FORESIGHT_MODEL_WORKER` in `runtime.json`.
Generation continues through the packaged `litert-runner`. Linux packaging does
not copy this directory or include a Python runtime.

Generation accepts optional `--tools` JSON: either a legacy definitions array or
an object with `tools` and `system_message`. Object requests install the supplied
instructions in the native system role, keeping `--prompt` as user content.
System, tool and user tokens count toward the existing context admission limit.
Application requests also set `delegate_tool_detection: true`: every complete
model response waits for a Dart decision so the recovered native/text fallback
parser is shared by both backends. See [fallback evidence](../../../docs/reference-tool-fallback.md).
Memory compression uses an empty-tool object with empty system text and no
history, creating a separate plain local conversation. See [memory behavior](../../../docs/reference-chat-history.md).
It retains one conversation
while delegating callbacks to the application service over the private owned
process connection. The model subprocess performs no network requests or tool
callbacks itself. See [reference tool behavior](../../../docs/reference-tool-generation.md)
for protocol, ownership, tests and remaining production integration.

Experimental `--query-detector` mode uses a raw session with no chat template,
system instruction, tools or schema. Its fixed 512-token setting and single
candidate sampling follow the recovered detector options. CPU is currently a
port testing choice; dedicated-asset compatibility and production integration
remain unverified. See [runtime evidence](../../../docs/reference-query-runtime.md).

Generation also implements the versioned persistent worker protocol described
in [the shared inference README](../README.md#persistent-tool-worker). The pinned
Python engine remains loaded across tool requests; each request owns an isolated
conversation and receives a terminal acknowledgement only after that conversation
closes. The native application can cancel decoding through the same input pipe
without terminating the retained engine.
