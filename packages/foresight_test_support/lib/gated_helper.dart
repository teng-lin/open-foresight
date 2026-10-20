import 'dart:io';
import 'dart:isolate';

import 'poll.dart';

/// A helper executable that holds SIGTERM until [release], so a test can keep
/// a closing service inside its helper shutdown while it still owns the
/// profile lock. Point `FORESIGHT_HELPER` at [executable].
///
/// The behavior lives in `gated_helper.py`, which the built-service suite runs
/// as `tests/service/gated_helper.py`; both copies must stay identical.
class GatedHelper {
  GatedHelper._(this.control, this.executable);

  /// Holds the `started`, `stopping` and `release` files.
  final Directory control;

  /// A wrapper that runs the shared script with this helper's [control].
  final String executable;

  static Future<GatedHelper> create(Directory directory) async {
    final script = await Isolate.resolvePackageUri(
      Uri.parse('package:foresight_test_support/gated_helper.py'),
    );
    if (script == null) {
      throw StateError('Cannot locate the gated helper script');
    }
    final control = Directory('${directory.path}/helper-control')..createSync();
    final wrapper = File('${directory.path}/helper')
      ..writeAsStringSync(
        '#!/bin/sh\nexec /usr/bin/env python3 '
        '${_quote(script.toFilePath())} ${_quote(control.path)} "\$@"\n',
      );
    final protect = await Process.run('/bin/chmod', ['700', wrapper.path]);
    if (protect.exitCode != 0) {
      throw StateError('Cannot make ${wrapper.path} executable');
    }
    return GatedHelper._(control, wrapper.path);
  }

  /// The helper's pid once its SIGTERM handler is installed.
  Future<int> started({Duration timeout = const Duration(seconds: 30)}) =>
      _published('started', timeout);

  /// The helper's pid once SIGTERM arrived; it then waits for [release].
  Future<int> stopping({Duration timeout = const Duration(seconds: 30)}) =>
      _published('stopping', timeout);

  bool get isStopping => File('${control.path}/stopping').existsSync();

  /// Let a held (or later) SIGTERM finish. Safe to call more than once.
  void release() => File('${control.path}/release').writeAsStringSync('');

  Future<int> _published(String name, Duration timeout) async {
    final file = File('${control.path}/$name');
    await eventually(file.existsSync, timeout: timeout);
    return int.parse(file.readAsStringSync());
  }
}

String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
