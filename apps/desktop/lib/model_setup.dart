import 'package:foresight_core/desktop.dart' show StoreReader;
import 'package:foresight_core/desktop.dart' as core;

bool needsModel(StoreReader reader, String kind) =>
    core.readerNeedsModel(reader, kind);
String? speechSetupProblem(StoreReader reader) =>
    core.readerSpeechSetupProblem(reader);
String? dedicatedQuerySetupProblem(StoreReader reader) =>
    core.readerDedicatedQuerySetupProblem(reader);
