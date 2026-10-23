import 'package:flutter/widgets.dart';

abstract interface class PreferenceCommands {
  Future<void> preference(String key, String value);
}

abstract interface class SettingsCommands implements PreferenceCommands {
  Future<void> chooseSpeech();
  Future<void> chooseGemma({bool firstRun = false, bool embeddingOnly = false});
  void showModelSetup(String kind);
  Widget gemmaSetup({
    bool firstRun = false,
    bool embeddingOnly = false,
    VoidCallback? onDone,
  });
  Widget speechSetup({VoidCallback? onDone});
}
