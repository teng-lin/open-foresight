# Native runtime

The C ABI in `foresight_native.h` exposes owned generation, speech and capture workers. Build through the root CMake project, then run CTest for lifecycle and cancellation checks.

Generation supports explicit llama.cpp and LiteRT-LM workers. Local Gemma grounded requests use the versioned `x-foresight-grounded-request` schema annotation, consumed by `services/helper/grounded_generation.py`. It selects evidence units, composes text, checks source citations and numeric fidelity, and performs a separate support check. The configured context is 4096 tokens with a token-aware output reserve. Verification is fallible; failed drafts get one repair attempt followed by a labelled source fallback.

Capture uses PipeWire; speech uses whisper.cpp on mono PCM. Workers own their subprocess groups, cancel them on request, and reap them before releasing resources. Model assets and executable paths must be registered explicitly. Deterministic lifecycle tests do not establish real-model quality; real-model tests are opt-in.
