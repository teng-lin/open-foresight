/// The sole implementation boundary for in-process desktop fixtures.
/// Tests own disposable writable applications; production uses desktop.dart.
library;

export 'package:foresight_core/src/agent_access.dart';
export 'package:foresight_core/src/answer_source_scope.dart';
export 'package:foresight_core/src/application.dart';
export 'package:foresight_core/src/application_services/audio_operations.dart';
export 'package:foresight_core/src/audio_devices.dart';
export 'package:foresight_core/src/domain.dart';
export 'package:foresight_core/src/gemma_download.dart';
export 'package:foresight_core/src/generated/helper_control.pb.dart';
export 'package:foresight_core/src/generated/helper_control.pbgrpc.dart';
export 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
export 'package:foresight_core/src/google_auth.dart';
export 'package:foresight_core/src/google_connections.dart';
export 'package:foresight_core/src/graph_clusters.dart';
export 'package:foresight_core/src/graph_labels.dart';
export 'package:foresight_core/src/graph_layout.dart';
export 'package:foresight_core/src/helper.dart';
export 'package:foresight_core/src/native.dart';
export 'package:foresight_core/src/operations.dart';
export 'package:foresight_core/src/persistence/sqlite_runtime.dart' hide Row;
export 'package:foresight_core/src/platform_services.dart';
export 'package:foresight_core/src/profile_paths.dart';
export 'package:foresight_core/src/read_coordinator.dart';
export 'package:foresight_core/src/recording.dart';
export 'package:foresight_core/src/rpc_error.dart';
export 'package:foresight_core/src/speech_models.dart';
export 'package:foresight_core/src/sqlite_read_session.dart';
export 'package:foresight_core/src/sqlite_store_reader.dart';
export 'package:foresight_core/src/store.dart';

export 'package:foresight_core/src/diagnostics/session.dart'
    show
        LoggingSession,
        DiagnosticConfiguration,
        DiagnosticEvent,
        DiagnosticComponent,
        DiagnosticHealthState,
        DiagnosticIdentity;
export 'package:foresight_core/src/diagnostics/storage.dart'
    show DiagnosticSink, DiagnosticRole;
