import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'operations.g.dart';
import 'code_locations.g.dart';
import 'configuration.dart';

export 'configuration.dart';

enum DiagnosticComponent {
  desktop,
  service,
  domain,
  mcp,
  helper,
  native,
  capture,
  storage,
  logging,
  tool,
}

enum DiagnosticProducerKind {
  entrypoint,
  domain,
  desktopReader,
  nativeDrain,
  setup,
  parser,
  audio,
  writer,
}

enum DiagnosticCategory {
  internal,
  validation,
  cancelled,
  closing,
  timeout,
  transport,
  protocol,
  permission,
  storage,
  unavailable,
  process,
  unknown,
}

enum DiagnosticOutcome {
  started,
  ready,
  completed,
  failed,
  cancelled,
  refused,
  contended,
  withdrawn,
  unknown,
}

enum DiagnosticProvider { google, granola, local, unknown }

enum DiagnosticField {
  operation,
  category,
  outcome,
  provider,
  status,
  signal,
  bytes,
  count,
  dropped,
  durationUs,
  attempt,
  queued,
  active,
  enabled,
  event,
  firstMs,
  lastMs,
}

enum DiagnosticEvent {
  serviceStarting('service.starting', DiagnosticLevel.info),
  serviceReady('service.ready', DiagnosticLevel.info),
  serviceStopped('service.stopped', DiagnosticLevel.info),
  rpcCompleted('rpc.completed', DiagnosticLevel.info),
  rpcFailed('rpc.failed', DiagnosticLevel.error),
  invalidFrame('transport.invalid_frame', DiagnosticLevel.warn),
  transportActivity('transport.activity', DiagnosticLevel.trace),
  helperExited('helper.exited', DiagnosticLevel.warn),
  nativeWorkerFailed('native.worker_failed', DiagnosticLevel.error),
  captureStateChanged('capture.state_changed', DiagnosticLevel.info),
  runtimeFailed('runtime.failed', DiagnosticLevel.error),
  authChanged('auth.changed', DiagnosticLevel.info),
  recordsDropped('logging.records_dropped', DiagnosticLevel.warn),
  recordRejected('logging.record_rejected', DiagnosticLevel.warn),
  invalidConfiguration('logging.invalid_configuration', DiagnosticLevel.warn);

  const DiagnosticEvent(this.wire, this.severity);
  final String wire;
  final DiagnosticLevel severity;
  Set<DiagnosticField> get fields => switch (this) {
    serviceStarting || serviceReady || serviceStopped => const {
      DiagnosticField.outcome,
      DiagnosticField.durationUs,
      DiagnosticField.count,
    },
    rpcCompleted || rpcFailed => const {
      DiagnosticField.operation,
      DiagnosticField.category,
      DiagnosticField.outcome,
      DiagnosticField.durationUs,
      DiagnosticField.status,
      DiagnosticField.attempt,
    },
    invalidFrame || transportActivity => const {
      DiagnosticField.category,
      DiagnosticField.bytes,
      DiagnosticField.count,
    },
    helperExited || nativeWorkerFailed => const {
      DiagnosticField.category,
      DiagnosticField.outcome,
      DiagnosticField.status,
      DiagnosticField.signal,
      DiagnosticField.bytes,
      DiagnosticField.dropped,
    },
    captureStateChanged => const {
      DiagnosticField.outcome,
      DiagnosticField.category,
      DiagnosticField.queued,
      DiagnosticField.active,
      DiagnosticField.durationUs,
    },
    runtimeFailed => const {
      DiagnosticField.category,
      DiagnosticField.status,
      DiagnosticField.outcome,
    },
    authChanged => const {
      DiagnosticField.provider,
      DiagnosticField.outcome,
      DiagnosticField.category,
      DiagnosticField.durationUs,
    },
    recordsDropped || recordRejected => const {
      DiagnosticField.count,
      DiagnosticField.dropped,
      DiagnosticField.category,
      DiagnosticField.event,
      DiagnosticField.firstMs,
      DiagnosticField.lastMs,
    },
    invalidConfiguration => const {},
  };
}

/// Closed operation identity projected from the application's registry. Parsing
/// unknown wire strings returns null; runtime bootstrap imports no descriptors.
final class DiagnosticOperation {
  const DiagnosticOperation._(this.wire);
  final String wire;
  static DiagnosticOperation? parse(String wire) =>
      diagnosticOperations.contains(wire) ? DiagnosticOperation._(wire) : null;
}

/// Random identities only. A wire bridge must additionally pass the service's
/// authenticated peer checks; this shape never grants application authority.
final class DiagnosticIdentity {
  DiagnosticIdentity.random([Random? random])
    : value = _random(random ?? Random.secure());
  DiagnosticIdentity._(this.value);
  final String value;
  static String _random(Random random) => List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  static DiagnosticIdentity? parse(String value) =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(value)
      ? DiagnosticIdentity._(value)
      : null;
}

/// A stack contains registered code-location indices and bounded coordinates,
/// never exception messages, symbols, absolute paths or caller-provided hashes.
final class SafeDiagnosticStack {
  SafeDiagnosticStack._(this.frames, this.fingerprint);
  final List<List<int>> frames;
  final String fingerprint;

  /// Compatibility for raw caught/VM stacks. Dart exposes their frames only
  /// through arbitrary toString(), so they cannot be safely projected within
  /// the logger's encoding budget. Retain category, omit optional frames.
  factory SafeDiagnosticStack.encode(
    StackTrace stack,
    DiagnosticCategory category,
  ) => SafeDiagnosticStack.fromRegisteredLocations(const [], category);

  /// A representation already bounded by its independent trusted source. Never
  /// obtain this text by moving a raw StackTrace.toString() to a logging caller.
  /// Oversized input is omitted before regex/substring/UTF8 materialization.
  static const maximumInputCharacters = 1024;
  factory SafeDiagnosticStack.fromBoundedText(
    String text,
    DiagnosticCategory category,
  ) {
    if (text.length > maximumInputCharacters) {
      return SafeDiagnosticStack.fromRegisteredLocations(const [], category);
    }
    final frames = <List<int>>[];
    const prefix = '(package:foresight_core/';
    var cursor = 0;
    while (frames.length < 8) {
      final marker = text.indexOf(prefix, cursor);
      if (marker < 0) break;
      final pathStart = marker + prefix.length;
      cursor = pathStart;
      var index = -1, pathEnd = 0;
      for (
        var candidate = 0;
        candidate < diagnosticCodeLocations.length;
        candidate++
      ) {
        final path = diagnosticCodeLocations[candidate];
        final end = pathStart + path.length;
        if (end < text.length &&
            text.codeUnitAt(end) == 58 &&
            text.startsWith(path, pathStart)) {
          index = candidate;
          pathEnd = end;
          break;
        }
      }
      if (index < 0) continue;
      final line = _coordinate(text, pathEnd + 1, 7, 58);
      if (line == null) continue;
      final column = _coordinate(text, line.$2, 5, 41);
      if (column == null) continue;
      frames.add([index, line.$1, column.$1]);
      cursor = column.$2;
    }
    return SafeDiagnosticStack.fromRegisteredLocations(frames, category);
  }

  static (int, int)? _coordinate(
    String text,
    int start,
    int digits,
    int separator,
  ) {
    var value = 0, cursor = start;
    while (cursor < text.length && cursor - start < digits) {
      final character = text.codeUnitAt(cursor);
      if (character < 48 || character > 57) break;
      value = value * 10 + character - 48;
      cursor++;
    }
    if (cursor == start ||
        cursor >= text.length ||
        text.codeUnitAt(cursor) != separator) {
      return null;
    }
    return (value, cursor + 1);
  }

  /// Numeric frames already supplied by a bounded trusted producer. Indices are
  /// this build's generated code registry, not arbitrary caller fingerprints.
  factory SafeDiagnosticStack.fromRegisteredLocations(
    List<List<int>> locations,
    DiagnosticCategory category,
  ) {
    final frames = <List<int>>[];
    if (locations.length <= 8) {
      for (final frame in locations) {
        if (frame.length != 3 ||
            frame[0] < 0 ||
            frame[0] >= diagnosticCodeLocations.length ||
            frame[1] < 0 ||
            frame[1] > 9999999 ||
            frame[2] < 0 ||
            frame[2] > 99999) {
          continue;
        }
        frames.add(List<int>.unmodifiable(frame));
      }
    }
    return SafeDiagnosticStack._(
      List.unmodifiable(frames),
      sha256
          .convert(utf8.encode(jsonEncode([category.index, frames])))
          .toString(),
    );
  }

  Map<String, Object> toWire() => {
    'frames': frames,
    'fingerprint': fingerprint,
  };
}

final class DiagnosticRecord {
  DiagnosticRecord(
    this.event,
    this.component, {
    Map<DiagnosticField, Object> fields = const {},
    this.connection,
    this.request,
    this.attempt,
    this.job,
    this.stack,
    this.transport = false,
  }) : fields = Map.unmodifiable(fields);
  final DiagnosticEvent event;
  final DiagnosticComponent component;
  final Map<DiagnosticField, Object> fields;
  final DiagnosticIdentity? connection, job;
  final int? request, attempt;
  final SafeDiagnosticStack? stack;
  final bool transport;
  static const maximumRecordBytes = 16 * 1024;
  // Registered scalar fields+eight numeric frames are below this producer cap.
  // It also bounds temporary UTF16/UTF8 encoding scratch across16 producers.
  static const maximumProducerRecordBytes = 2048;

  Map<String, Object?>? toWire() {
    if ((request != null && !_number(request!, signed: false)) ||
        (attempt != null && !_number(attempt!, signed: false))) {
      return null;
    }
    final values = <String, Object>{};
    for (final entry in fields.entries) {
      if (!event.fields.contains(entry.key)) return null;
      final value = switch (entry.value) {
        DiagnosticOperation op => op.wire,
        DiagnosticEvent event => event.wire,
        DiagnosticCategory category => category.name,
        DiagnosticOutcome outcome => outcome.name,
        DiagnosticProvider provider => provider.name,
        int number => number,
        bool boolean => boolean,
        _ => null,
      };
      if (value == null || !_validField(entry.key, value)) return null;
      values[entry.key.name] = value;
    }
    return {
      'event': event.wire,
      'component': component.name,
      'fields': values,
      if (connection != null) 'connection': connection!.value,
      if (request != null) 'request': request,
      if (attempt != null) 'attempt': attempt,
      if (job != null) 'job': job!.value,
      if (stack != null) 'stack': stack!.toWire(),
    };
  }

  static bool _number(int value, {bool signed = true}) =>
      value >= (signed ? -0x7fffffff : 0) && value <= 0x7fffffff;
  static bool _validField(
    DiagnosticField field,
    Object? value,
  ) => switch (field) {
    DiagnosticField.operation =>
      value is String &&
          value.length <= 96 &&
          diagnosticOperations.contains(value),
    DiagnosticField.event =>
      value is String &&
          DiagnosticEvent.values.any((event) => event.wire == value),
    DiagnosticField.category =>
      value is String && DiagnosticCategory.values.any((v) => v.name == value),
    DiagnosticField.outcome =>
      value is String && DiagnosticOutcome.values.any((v) => v.name == value),
    DiagnosticField.provider =>
      value is String && DiagnosticProvider.values.any((v) => v.name == value),
    DiagnosticField.active || DiagnosticField.enabled => value is bool,
    DiagnosticField.status ||
    DiagnosticField.signal => value is int && _number(value),
    _ => value is int && _number(value, signed: false),
  };

  /// Writer/subprocess boundary validation rejects unknown keys or any arbitrary
  /// string. This also validates internally encoded records after transport.
  static bool validWire(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !const <String>{
            'event',
            'component',
            'fields',
            'connection',
            'request',
            'attempt',
            'job',
            'stack',
          }.contains(key),
        )) {
      return false;
    }
    final event = DiagnosticEvent.values
        .where((event) => event.wire == value['event'])
        .firstOrNull;
    if (event == null ||
        !DiagnosticComponent.values.any(
          (component) => component.name == value['component'],
        ) ||
        value['fields'] is! Map<String, dynamic>) {
      return false;
    }
    for (final entry in (value['fields'] as Map<String, dynamic>).entries) {
      final field = DiagnosticField.values
          .where((field) => field.name == entry.key)
          .firstOrNull;
      if (field == null ||
          !event.fields.contains(field) ||
          !_validField(field, entry.value)) {
        return false;
      }
    }
    for (final key in ['connection', 'job']) {
      if (value.containsKey(key) &&
          (value[key] is! String ||
              DiagnosticIdentity.parse(value[key] as String) == null)) {
        return false;
      }
    }
    for (final key in ['request', 'attempt']) {
      if (value.containsKey(key) &&
          (value[key] is! int || !_number(value[key] as int, signed: false))) {
        return false;
      }
    }
    if (value['stack'] case final Object stack) {
      if (stack is! Map<String, dynamic> ||
          stack.length != 2 ||
          stack['frames'] is! List ||
          (stack['frames'] as List).length > 8 ||
          stack['fingerprint'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(stack['fingerprint'] as String)) {
        return false;
      }
      for (final frame in stack['frames'] as List) {
        if (frame is! List ||
            frame.length != 3 ||
            frame.any(
              (number) => number is! int || number < 0 || number > 9999999,
            ) ||
            (frame.first as int) >= diagnosticCodeLocations.length) {
          return false;
        }
      }
      // Fingerprints are recomputed from numeric frames and the closed category;
      // an otherwise valid hex string cannot smuggle caller-provided identity.
      final category =
          DiagnosticCategory.values
              .where(
                (category) =>
                    category.name == (value['fields'] as Map)['category'],
              )
              .firstOrNull ??
          DiagnosticCategory.unknown;
      if (stack['fingerprint'] !=
          sha256
              .convert(
                utf8.encode(jsonEncode([category.index, stack['frames']])),
              )
              .toString()) {
        return false;
      }
    }
    return true;
  }
}
