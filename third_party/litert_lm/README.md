Public C API headers and model-header schema from Google LiteRT-LM v0.18.0,
commit b2f686e2ed4718fb84ec398a61dd59ca0f0aff27.
https://github.com/google-ai-edge/LiteRT-LM/tree/v0.18.0
Licensed under Apache-2.0; see LICENSE and individual files.
No Google Foresight private ABI is used.

`c/foresight_extensions.h` is an Open Foresight extension, not an upstream
0.18.0 API. `stop-token-sequences.patch` implements it in that exact upstream
source and extends the Python wrapper before session config copying. See
`docs/models/reference-native-stop-tokens.md` and `tools/build_litert_extensions.py`
at the repository root. The published stock libraries do not export it.
