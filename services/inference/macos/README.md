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
