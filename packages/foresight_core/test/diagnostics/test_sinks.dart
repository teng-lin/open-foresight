import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foresight_core/src/diagnostics/events.dart';
import 'package:foresight_core/src/diagnostics/storage.dart';

DiagnosticSinkFactory memorySink(SendPort output) =>
    (String _, DiagnosticIdentity __, DiagnosticRole ___) => MemorySink(output);
DiagnosticSinkFactory brokenSink(SendPort output) =>
    (String _, DiagnosticIdentity __, DiagnosticRole ___) =>
        MemorySink(output, broken: true);

DiagnosticSinkFactory contendedSink(SendPort output) =>
    (String _, DiagnosticIdentity __, DiagnosticRole ___) =>
        MemorySink(output, contended: true);

final class MemorySink implements DiagnosticSink {
  MemorySink(this.output, {this.broken = false, this.contended = false});
  final SendPort output;
  final bool broken, contended;
  @override
  int get slot => 7;
  @override
  bool get failed => broken;
  @override
  bool classify(
    DiagnosticRole role, {
    required bool error,
    bool genuineFailure = false,
  }) {
    output.send({
      'classified': role.name,
      'error': error,
      'failure': genuineFailure,
    });
    return !contended;
  }

  @override
  bool append(Uint8List record) {
    if (broken) throw StateError('secret canary must never escape sink');
    output.send(jsonDecode(utf8.decode(record)));
    return true;
  }

  @override
  void close() {
    output.send('sink_closed');
  }
}

final class SinkCapture {
  SinkCapture() {
    port.listen((dynamic value) {
      if (value == 'sink_closed') {
        if (!closed.isCompleted) closed.complete();
      } else {
        messages.add(value);
      }
    });
  }
  final port = ReceivePort();
  final messages = <dynamic>[];
  final closed = Completer<void>();
  List<Map<String, dynamic>> get records => messages
      .whereType<Map>()
      .where((value) => value.containsKey('schema'))
      .map((value) => Map<String, dynamic>.from(value))
      .toList();
  void dispose() => port.close();
}
