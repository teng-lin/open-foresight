import 'dart:convert';
import 'dart:typed_data';

import 'bounded_json.dart';
import 'events.dart';
import 'storage.dart';

abstract final class DiagnosticWorkerFrame {
  static const hello = 1,
      init = 2,
      result = 3,
      admit = 4,
      classify = 5,
      append = 6,
      health = 7,
      retire = 8,
      retired = 9;
  static const maximumRequestBytes = 8192,
      maximumReplyBytes = 512,
      maximumRecordBytes = DiagnosticRecord.maximumRecordBytes;
}

Never _invalid() => throw const FormatException('Invalid diagnostic payload');

bool _hex(String value, int length) {
  if (value.length != length) return false;
  for (final unit in value.codeUnits) {
    if ((unit < 48 || unit > 57) && (unit < 97 || unit > 102)) return false;
  }
  return true;
}

/// INIT alone carries the private profile; no JSON expansion or environment.
/// Version/schema/role/reserved, raw16-byte session and a u16BE UTF8 length are
/// fixed at offsets4/5/6/7,8 and24. No file authority is granted by decoding.
final class DiagnosticWorkerInit {
  DiagnosticWorkerInit({
    required this.profile,
    required this.session,
    required this.role,
  });
  final String profile;
  final DiagnosticIdentity session;
  final DiagnosticRole role;

  // Supported hosts use POSIX paths. Scan canonical segments directly rather
  // than allocating normalized segment/separator lists for a rejected profile.
  static bool _profile(String value) {
    if (value.length <= 1 || value.length > 4096 || value.codeUnitAt(0) != 47) {
      return false;
    }
    var start = 1;
    for (var i = 1; i <= value.length; i++) {
      final unit = i == value.length ? 47 : value.codeUnitAt(i);
      if (unit == 0) return false;
      if (unit != 47) continue;
      final length = i - start;
      if (length == 0 ||
          (length == 1 && value.codeUnitAt(start) == 46) ||
          (length == 2 &&
              value.codeUnitAt(start) == 46 &&
              value.codeUnitAt(start + 1) == 46)) {
        return false;
      }
      start = i + 1;
    }
    return true;
  }

  Uint8List encode() {
    if (!_profile(profile) || role == DiagnosticRole.transient) _invalid();
    final name = utf8.encode(profile);
    if (name.length > 4096) _invalid();
    final result = Uint8List(26 + name.length);
    result.setRange(0, 8, [79, 70, 68, 73, 1, 2, role.index, 0]);
    for (var i = 0; i < 16; ++i) {
      result[8 + i] = int.parse(
        session.value.substring(i * 2, i * 2 + 2),
        radix: 16,
      );
    }
    ByteData.sublistView(result).setUint16(24, name.length, Endian.big);
    result.setRange(26, result.length, name);
    return result;
  }

  static DiagnosticWorkerInit decode(Uint8List bytes) {
    if (bytes.length < 27 ||
        bytes.length > 4122 ||
        bytes[0] != 79 ||
        bytes[1] != 70 ||
        bytes[2] != 68 ||
        bytes[3] != 73 ||
        bytes[4] != 1 ||
        bytes[5] != 2 ||
        bytes[7] != 0 ||
        bytes[6] >= DiagnosticRole.transient.index) {
      _invalid();
    }
    final count = ByteData.sublistView(bytes).getUint16(24, Endian.big);
    if (count == 0 || count > 4096 || bytes.length != 26 + count) _invalid();
    final profile = utf8.decode(Uint8List.sublistView(bytes, 26));
    if (!_profile(profile)) _invalid();
    final session = StringBuffer();
    for (var i = 8; i < 24; ++i) {
      session.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return DiagnosticWorkerInit(
      profile: profile,
      session: DiagnosticIdentity.parse(session.toString())!,
      role: DiagnosticRole.values[bytes[6]],
    );
  }
}

final class DiagnosticWorkerClassification {
  const DiagnosticWorkerClassification(
    this.role, {
    required this.error,
    required this.genuineFailure,
  });
  final DiagnosticRole role;
  final bool error, genuineFailure;

  Uint8List encode() {
    if (role == DiagnosticRole.transient || (genuineFailure && !error)) {
      _invalid();
    }
    return Uint8List.fromList([
      role.index,
      error ? 1 : 0,
      genuineFailure ? 1 : 0,
    ]);
  }

  static DiagnosticWorkerClassification decode(Uint8List bytes) {
    if (bytes.length != 3 ||
        bytes[0] >= DiagnosticRole.transient.index ||
        bytes[1] > 1 ||
        bytes[2] > 1 ||
        (bytes[2] == 1 && bytes[1] == 0)) {
      _invalid();
    }
    return DiagnosticWorkerClassification(
      DiagnosticRole.values[bytes[0]],
      error: bytes[1] == 1,
      genuineFailure: bytes[2] == 1,
    );
  }
}

enum DiagnosticWorkerResult { ok, retry, disabled }

/// Closed four-byte replies contain no profile, content or error strings.
final class DiagnosticWorkerReply {
  const DiagnosticWorkerReply(this.result, this.reason, {this.slot});
  final DiagnosticWorkerResult result;
  final DiagnosticHealthReason reason;
  final int? slot;

  Uint8List encode() {
    if (slot != null && (slot! < 0 || slot! >= 10)) _invalid();
    return Uint8List.fromList([
      1,
      result.index,
      reason.index,
      (slot ?? -1) + 1,
    ]);
  }

  static DiagnosticWorkerReply decode(Uint8List bytes) {
    if (bytes.length != 4 ||
        bytes[0] != 1 ||
        bytes[1] >= DiagnosticWorkerResult.values.length ||
        bytes[2] >= DiagnosticHealthReason.values.length ||
        bytes[3] > 10) {
      _invalid();
    }
    return DiagnosticWorkerReply(
      DiagnosticWorkerResult.values[bytes[1]],
      DiagnosticHealthReason.values[bytes[2]],
      slot: bytes[3] == 0 ? null : bytes[3] - 1,
    );
  }
}

/// Returns the authenticated strictly increasing schema2 sequence, or null.
/// Legacy schema1 decoding belongs to catalog-aware readers, never this sink.
({int sequence, DiagnosticLevel level})? diagnosticStoredRecord(
  Uint8List bytes, {
  required String buildId,
  required String session,
  required int parentPid,
  required int afterSequence,
}) {
  if (!diagnosticRecordJsonShape(bytes)) return null;
  try {
    final value = jsonDecode(String.fromCharCodes(bytes, 0, bytes.length - 1));
    const header = {
      'schema',
      'timestamp',
      'sequence',
      'level',
      'version',
      'revision',
      'session',
      'pid',
      'producer',
      'build_id',
    };
    const body = {
      'event',
      'component',
      'fields',
      'connection',
      'request',
      'attempt',
      'job',
      'stack',
    };
    if (value is! Map<String, dynamic> ||
        value.keys.any((key) => !header.contains(key) && !body.contains(key)) ||
        !header.every(value.containsKey) ||
        value['schema'] != 2 ||
        value['build_id'] != buildId ||
        !_hex(buildId, 64) ||
        value['session'] != session ||
        DiagnosticIdentity.parse(session) == null ||
        value['pid'] != parentPid ||
        parentPid <= 1 ||
        parentPid > 0x7fffffff ||
        value['sequence'] is! int ||
        (value['sequence'] as int) <= 0 ||
        (value['sequence'] as int) <= afterSequence ||
        (value['sequence'] as int) > 0x7fffffffffffffff) {
      return null;
    }
    final timestamp = value['timestamp'];
    if (timestamp is! String ||
        timestamp.length > 27 ||
        DateTime.parse(timestamp).toUtc().toIso8601String() != timestamp) {
      return null;
    }
    final version = value['version'], revision = value['revision'];
    if (version is! String ||
        version.length > 48 ||
        !RegExp(
          r'^(unknown|[0-9]+\.[0-9]+\.[0-9]+(?:[-+][a-zA-Z0-9.]{1,20})?)$',
        ).hasMatch(version) ||
        revision is! String ||
        !(revision == 'unknown' || _hex(revision, 40))) {
      return null;
    }
    final producer = value['producer'];
    if (producer is! String || producer.length > 64) return null;
    if (producer != 'writer:0:0') {
      final parts = producer.split(':');
      if (parts.length != 3 ||
          !DiagnosticProducerKind.values.any(
            (kind) =>
                kind != DiagnosticProducerKind.writer && kind.name == parts[0],
          )) {
        return null;
      }
      final slot = int.tryParse(parts[1]), generation = int.tryParse(parts[2]);
      if (slot == null ||
          slot < 0 ||
          slot >= 16 ||
          '$slot' != parts[1] ||
          generation == null ||
          generation <= 0 ||
          generation > 0x7fffffffffffffff ||
          '$generation' != parts[2]) {
        return null;
      }
    }
    final record = <String, dynamic>{
      for (final key in body)
        if (value.containsKey(key)) key: value[key],
    };
    if ((record.containsKey('stack') && record['stack'] == null) ||
        !DiagnosticRecord.validWire(record)) {
      return null;
    }
    final category = (record['fields'] as Map)['category'];
    final level = category == DiagnosticCategory.cancelled.name
        ? DiagnosticLevel.debug
        : category == DiagnosticCategory.closing.name
        ? DiagnosticLevel.info
        : DiagnosticEvent.values
              .firstWhere((event) => event.wire == record['event'])
              .severity;
    if (value['level'] != level.name) return null;
    return (sequence: value['sequence'] as int, level: level);
  } on FormatException {
    return null;
  }
}
