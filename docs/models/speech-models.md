# Transcription models

The speech runner is whisper.cpp. Earlier installations may register `ggml-tiny.en.bin`, an English-only model. Existing registrations remain selected until the user changes them. The model picker offers multilingual Tiny, Base, Small, Medium, and Large v3 Turbo, with pinned revisions, byte counts, and SHA-256 checks. Small balances download size and multilingual capability; Large v3 Turbo is another option for stronger recognition. Rapid Chinese/English switching still requires representative meeting evaluation.

The runner now uses `-l auto` rather than forcing English and does not request translation. Chinese speech remains Chinese text; English remains English text. Language detection runs per recording chunk. The active `FORESIGHT_WHISPER_BACKEND` and `FORESIGHT_WHISPER_DEVICE` settings apply to both the setup probe and transcription; the packaged NVIDIA runner normally uses Vulkan device 1 on this machine.

Downloaded speech models live below the model directory shown in the picker, normally `<application profile>/models/whisper/<filename>-<sha256 prefix>/<filename>`. Existing external registrations continue to use their original paths. Downloaded bytes are verified before publication and reuse. Selecting an already active valid model finishes without downloading or loading it again. Selecting an inactive cached model verifies and loads it before switching. Setup decodes generated silence to validate the runner/model/device, then registers the model. A failed or cancelled setup preserves the previous registration. Setup never captures the microphone.

Official references, checked 2026-10-15:

- [OpenAI Whisper model family and multilingual behavior](https://github.com/openai/whisper).
- [Official whisper.cpp model artifacts at the pinned revision](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1).
- [NVIDIA Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) covers 25 European languages, rather than Mandarin.
- [NVIDIA Parakeet CTC Mandarin/English Code Switch](https://build.nvidia.com/nvidia/parakeet-ctc-0_6b-zh-cn/modelcard) is a separate 600M-parameter model trained on Mandarin and English, with Linux and RTX 50xx listed. It uses Triton, rather than whisper.cpp.
- [Official local Mandarin NIM deployment](https://docs.nvidia.com/nim/speech/26.10.0/asr/deploy-asr-models/parakeet-ctc-zh-cn.html) requires the NVIDIA container runtime, NGC access/API key, the model container, and a separate service/client integration. It exposes streaming and offline interfaces. This backend is not currently offered by the Whisper picker.

A controlled test with the bundled Chinese and English notification audio, concatenated outside the repository, was decoded by the verified Small model through the native speech API on NVIDIA Vulkan. This validates the original-language plumbing on a short bilingual fixture, rather than establishing conversational code-switch accuracy or streaming quality. No meeting audio or microphone was captured for this test.
