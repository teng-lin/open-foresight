import 'dart:io';
import 'package:open_foresight/desktop_environment.dart';

/// Model setup preflight is a process boundary, separate from model activation.
DesktopEnvironment setupEnvironment({
  void Function(String, List<String>)? started,
}) => DesktopEnvironment(
  start: (executable, arguments) async {
    started?.call(executable, arguments);
    return _SetupProcess();
  },
);

class _SetupProcess implements Process {
  @override
  Future<int> get exitCode async => 0;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
