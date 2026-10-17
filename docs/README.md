# Documentation

Start with the [project README](../README.md) for installation and usage.
Validation ledgers distinguish implemented support, controlled tests, live-service
acceptance, and release gates. Historical test counts describe their recorded
runs rather than the current test suite.

## Architecture and platforms

- [Application service and MCP](architecture/application-service.md)
- [Linux packaging and CI](platforms/linux-packaging.md)
- [macOS build, bundle, and installation](platforms/macos-support.md)
- [macOS CI timing and parallel gates](platforms/ci-performance.md)
- [macOS support plan and remaining acceptance gates](platforms/macos-support-plan.md)
- [macOS audio feasibility](platforms/macos-audio-feasibility.md)
- [Windows support plan](platforms/windows-support-plan.md)

## Validation and release status

- [Feature parity progress](validation/feature-parity-progress.md)
- [macOS validation](validation/macos-validation.md)
- [Production models and packaged runtime acceptance](validation/reference-production-runtime-acceptance.md)
- [Native inference replacement validation](validation/native-inference-validation.md)
- [Desktop UI parity validation](validation/ui-parity-validation.md)
- [Exact desktop UI behavior](validation/reference-exact-ui-behavior.md)

## Models and inference

- [Speech models](models/speech-models.md)
- [Model acquisition and encrypted storage](models/reference-model-acquisition.md)
- [Distribution asset and vision startup lifecycle](models/reference-model-lifecycle.md)
- [Dedicated query runtime investigation](models/reference-query-runtime.md)
- [Legacy detector runtime](models/reference-legacy-detector-runtime.md)
- [Tokenizer evidence](models/reference-tokenizer.md)
- [Native stop-token support](models/reference-native-stop-tokens.md)
- [GPU runtime dependencies and ABI](models/reference-gpu-runtime-closure.md)

## Chat, tools, and cloud services

- [Chat history and memory](chat/reference-chat-history.md)
- [Chat response processing](chat/reference-chat-response.md)
- [Streaming and retained workers](chat/reference-chat-streaming.md)
- [Web sources and citations](chat/reference-chat-web.md)
- [Native tool generation](chat/reference-tool-generation.md)
- [Textual tool fallback](chat/reference-tool-fallback.md)
- [Web content summaries](chat/reference-web-content.md)
- [Cloud transport acceptance](chat/reference-live-cloud-services.md)
- [Search investigation](chat/ida-search-investigation.md)

## Notes and exports

- [Note enhancement producer](notes/reference-note-enhancement.md)
- [Enhancement planning and merging](notes/reference-note-enhancement-planning.md)
- [Live enhancement scheduling](notes/reference-note-live-scheduling.md)
- [Note service readiness and recovery](notes/reference-note-service-recovery.md)
- [Note enhancement cleanup and error edges](notes/reference-note-enhancement-error-edges.md)
- [Transcript cache and enhancement lifecycle](notes/reference-note-lifecycle.md)
- [Saved transcript parsing](notes/reference-saved-transcript-parsing.md)
- [Note saving](notes/reference-note-save.md)
- [Meeting Markdown export](notes/reference-meeting-export.md)

## Recording and automatic answers

- [Recording recovery](recording/recording-recovery.md)
- [Recording device parity](recording/recording-device-parity.md)
- [Proactive question detection and dispatch](recording/proactive-reference-trace.md)

## Research and historical records

- [Reverse-engineering method with REA and herdr](research/rea-linux-and-herdr-mac.md)
- [Source labels](research/reference-source-labels.md)

The archive retains completed plans and earlier cross-feature investigations for
their revision-specific evidence. Use the topic documents and validation ledgers
above for current behavior and remaining work.

- [Completed application-service implementation plan and audit](archive/application-service-plan.md)
- [Historical missing-function reconstruction](archive/missing-functions-investigation.md)
