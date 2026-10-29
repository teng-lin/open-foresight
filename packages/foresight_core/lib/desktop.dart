/// Capabilities available to desktop features. Persistence, native runtimes and
/// helper transports remain private to the application service.
library;

export 'src/desktop_connection.dart';
export 'src/desktop_status.dart';
export 'src/read_models.dart';
export 'src/helper_status.dart';
export 'src/recording_status.dart' show RecordingSnapshot;
export 'src/store_reader.dart';
export 'src/store_read_queries.dart';
export 'src/read_coordinator.dart' show ReadQuery, ReadResult, ReadFreshness;
export 'src/operations.dart' show Operation;
export 'src/pending_request_key.dart';
export 'src/rpc_error.dart' show RpcError, RpcErrorCode, RpcErrorReason;
export 'src/audio_device.dart';
export 'src/desktop_audio.dart';
export 'src/file_discovery.dart'
    show DiscoveredLocalFile, LocalFileScan, LocalFileDiscovery;
export 'src/model_catalog.dart';
export 'src/model_cache.dart';
export 'src/model_download_contract.dart';
export 'src/model_asset_status.dart';
export 'src/desktop_model_downloads.dart';
export 'src/model_host_info.dart';
export 'src/speech_model_catalog.dart' show speechModels;
export 'src/granola_return_failure.dart';
export 'src/desktop_google_sources.dart';
export 'src/desktop_runtime_settings.dart';
export 'src/update_notice.dart';
export 'src/diagnostic_support.dart';
export 'src/source_type.dart' show SourceType, sourceType;
export 'src/graph_labels.dart'
    show DocumentLabel, graphLabelPalette, allocateGraphLabelColor;
export 'src/graph_clusters.dart' show GraphCluster;
export 'src/graph_layout.dart';
export 'src/force_layout.dart';
export 'src/label_propagation.dart';
export 'src/graph_view_data.dart'
    show
        StoredGraphLayout,
        graphLayoutAlgorithmVersion,
        graphDocumentSet,
        graphSceneSources;
export 'src/model_setup_status.dart'
    show
        preparedNeedsModel,
        preparedSpeechSetupProblem,
        preparedDedicatedQuerySetupProblem,
        dedicatedQueryModelDigest;
export 'src/dedicated_query_terms.dart'
    show dedicatedQueryTermsKey, dedicatedQueryTermsUri;
export 'src/meeting_speakers.dart' show MeetingSpeaker;
export 'src/attributed_transcript.dart'
    show AttributedTranscript, FormattedTranscriptLine, TranscriptFormatMode;
export 'src/output_calendar.dart';
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

export 'src/client_contract.dart';
export 'src/client_command.dart';
export 'src/client_requests.dart';
export 'src/operation_descriptors.dart';
export 'src/client_results.dart'
    show
        IntegerIdentityResult,
        SourceIdentityResult,
        AnswerTextResult,
        MeetingDetailResult,
        SourceSearchResult,
        NotificationResult,
        AudioCapabilityResult,
        DriveFileResult,
        DriveCapabilitiesResult,
        GoogleSignInResult,
        ServiceStatusResult,
        ServiceStopResult;
export 'src/operation_requests/graph_inputs.dart' show GraphSourceInput;
export 'src/operation_descriptor.dart' show OperationDescriptor;
export 'src/model_asset_failure.dart';

export 'src/audio_presentation.dart';
