import 'dart:io';
// ignore: implementation_imports
import 'package:foresight_core/src/recording.dart';

class TestRecording extends Recording {
  bool stopped = false;
  @override
  Future<void> stop() async {
    stopped = true;
    await super.stop();
  }

  TestRecording()
    : super(
        Platform.isMacOS ? '/usr/lib/libSystem.B.dylib' : 'libc.so.6',
        (_) {},
        (_, _, _, _) {},
      );
}
