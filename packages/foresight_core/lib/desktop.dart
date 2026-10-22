/// Capabilities available to desktop features. Persistence, native runtimes and
/// helper transports remain private to the application service.
library;

export 'src/desktop_connection.dart';
export 'src/desktop_read_models.dart';
export 'src/helper_status.dart';
export 'src/recording_status.dart' show RecordingSnapshot;
export 'src/store_reader.dart';
export 'src/store_read_queries.dart';
export 'src/read_coordinator.dart' show ReadQuery, ReadResult, ReadFreshness;
export 'src/operations.dart' show Operation;
export 'src/pending_request_key.dart';
export 'src/rpc_error.dart' show RpcError, RpcErrorCode, RpcErrorReason;
export 'src/audio_devices.dart' show AudioDevice, audioDevices;
export 'src/file_discovery.dart'
    show DiscoveredLocalFile, LocalFileScan, LocalFileDiscovery;
export 'src/gemma_download.dart'
    show
        GemmaModel,
        LocalModelFinder,
        GemmaDownload,
        ModelDownloadPhase,
        ModelDownloadCancelled,
        gemmaModels,
        embeddingGemmaModel,
        modelFromPin,
        localModelFile,
        verifyModelFile,
        availableModelDiskBytes,
        physicalMemoryGb;
export 'src/speech_models.dart' show speechModels;
export 'src/google_auth.dart' show GranolaReturnFailure;
export 'src/desktop_google_sources.dart';
export 'src/desktop_runtime_settings.dart';
export 'src/source_type.dart' show SourceType, sourceType;
export 'src/graph_labels.dart'
    show DocumentLabel, graphLabelPalette, allocateGraphLabelColor;
export 'src/graph_clusters.dart' show GraphCluster;
export 'src/graph_layout.dart';
export 'src/force_layout.dart';
export 'src/label_propagation.dart';
export 'src/graph_persistence.dart'
    show
        StoredGraphLayout,
        graphLayoutAlgorithmVersion,
        graphDocumentSet,
        graphSceneSources;
export 'src/model_setup.dart'
    show
        readerNeedsModel,
        readerSpeechSetupProblem,
        readerDedicatedQuerySetupProblem,
        dedicatedQueryModelDigest;
export 'src/dedicated_query_acquisition.dart'
    show dedicatedQueryTermsKey, dedicatedQueryTermsUri;
export 'src/meeting_speakers.dart' show MeetingSpeaker;
export 'src/store.dart' show outputWeekStart;
export 'src/platform_services.dart'
    show
        openPlatformUri,
        allowedSourceUri,
        writePrivateTextFile,
        platformNotification;
export 'src/version.dart'
    show
        openForesightVersion,
        openForesightBuildNumber,
        openForesightBuildLabel;
