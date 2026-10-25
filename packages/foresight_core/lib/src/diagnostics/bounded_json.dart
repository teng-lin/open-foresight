import 'dart:typed_data';

/// Encodes an already validated closed diagnostic schema in one fixed buffer.
/// Catalog strings and headers are printable ASCII without JSON escapes. This
/// is deliberately narrower than general JSON and fails closed on other input.
String diagnosticAsciiJsonString(
  Map<String, Object?> value, {
  required int maximumBytes,
}) {
  final encoder = _DiagnosticJsonEncoder(maximumBytes)..encode(value);
  return String.fromCharCodes(encoder.bytes, 0, encoder.length);
}

Uint8List diagnosticAsciiJsonBytes(
  Map<String, Object?> value, {
  required int maximumBytes,
}) {
  final encoder = _DiagnosticJsonEncoder(maximumBytes)
    ..encode(value, newline: true);
  return encoder.bytes.sublist(0, encoder.length);
}

final class _DiagnosticJsonEncoder {
  _DiagnosticJsonEncoder(int capacity) : _maximumBytes = _capacity(capacity);

  static int _capacity(int value) {
    if (value < 1 || value > 4096) {
      throw const FormatException('Invalid diagnostic JSON capacity');
    }
    return value;
  }

  int _maximumBytes;
  Uint8List? _buffer;
  Uint8List get bytes => _buffer!;
  int length = 0, _keys = 0, _tokens = 0;

  void encode(Map<String, Object?> value, {bool newline = false}) {
    // Both traversals are synchronous over the logger's validated plain maps.
    // The first bounds and counts bytes without an output allocation; the
    // second fills exactly that capacity, including the writer's newline.
    write(value, 0);
    if (newline) byte(10);
    _buffer = Uint8List(length);
    _maximumBytes = length;
    length = _keys = _tokens = 0;
    write(value, 0);
    if (newline) byte(10);
  }

  Never _invalid() =>
      throw const FormatException('Invalid diagnostic JSON value');

  void byte(int value) {
    if (length == _maximumBytes) _invalid();
    _buffer?[length] = value;
    ++length;
  }

  void _literal(String value) {
    for (var i = 0; i < value.length; ++i) {
      byte(value.codeUnitAt(i));
    }
  }

  void _string(String value) {
    if (value.length > 128) _invalid();
    byte(34);
    for (var i = 0; i < value.length; ++i) {
      final unit = value.codeUnitAt(i);
      if (unit < 32 || unit > 126 || unit == 34 || unit == 92) _invalid();
      byte(unit);
    }
    byte(34);
  }

  void write(Object? value, int depth) {
    if (++_tokens > 256) _invalid();
    if (value == null) {
      _literal('null');
    } else if (value is bool) {
      _literal(value ? 'true' : 'false');
    } else if (value is int) {
      _literal(value.toString());
    } else if (value is String) {
      _string(value);
    } else if (value is List) {
      if (depth == 4) _invalid();
      byte(91);
      for (var i = 0; i < value.length; ++i) {
        if (i != 0) byte(44);
        write(value[i], depth + 1);
      }
      byte(93);
    } else if (value is Map) {
      if (depth == 4) _invalid();
      byte(123);
      var first = true;
      value.forEach((key, element) {
        if (key is! String || ++_keys > 64) _invalid();
        if (!first) byte(44);
        first = false;
        _string(key);
        byte(58);
        write(element, depth + 1);
      });
      byte(125);
    } else {
      _invalid();
    }
  }
}

/// Closed ASCII JSON preflight before decoding. This bounds nesting, tokens,
/// strings and object keys and rejects duplicate keys in the original buffer.
/// It is not a JSON decoder: callers must still decode and validate their exact
/// schema. No strings escape from this scan and no regular files are opened.
bool diagnosticRecordJsonShape(Uint8List bytes) =>
    _preflight(bytes, manifest: false);

/// Manifests contain exactly eight flat scalar keys; no nested JSON is valid.
/// Known legacy manifest bytes remain supported. Record schema changes do not
/// change this metadata format.
bool diagnosticManifestJsonShape(Uint8List bytes) =>
    _preflight(bytes, manifest: true);

bool _preflight(Uint8List bytes, {required bool manifest}) {
  if (bytes.isEmpty || bytes.length > 4096 || (!manifest && bytes.last != 10)) {
    return false;
  }
  final limit = bytes.length - (manifest ? 0 : 1);
  final maximumDepth = manifest ? 1 : 4;
  final maximumKeys = manifest ? 8 : 64;
  final maximumTokens = manifest ? 64 : 256;
  final maximumString = manifest ? 64 : 128;
  final containers = Uint8List(maximumDepth),
      objects = Uint16List(maximumDepth);
  final keys = Uint16List(maximumKeys * 3);
  var depth = 0, nextObject = 0, keyCount = 0, tokens = 0;
  for (var i = 0; i < limit;) {
    final unit = bytes[i];
    if (unit == 32 || unit == 9) {
      ++i;
      continue;
    }
    if (++tokens > maximumTokens) return false;
    if (unit == 123 || unit == 91) {
      if (depth == maximumDepth) return false;
      containers[depth] = unit;
      objects[depth] = unit == 123 ? ++nextObject : 0;
      ++depth;
      ++i;
      continue;
    }
    if (unit == 125 || unit == 93) {
      if (depth == 0 || containers[depth - 1] != (unit == 125 ? 123 : 91)) {
        return false;
      }
      --depth;
      ++i;
      continue;
    }
    if (unit == 34) {
      final start = ++i;
      while (i < limit && bytes[i] != 34) {
        if (bytes[i] < 32 ||
            bytes[i] > 126 ||
            bytes[i] == 92 ||
            i - start >= maximumString) {
          return false;
        }
        ++i;
      }
      if (i == limit) return false;
      final count = i - start;
      var following = ++i;
      while (following < limit &&
          (bytes[following] == 32 || bytes[following] == 9)) {
        ++following;
      }
      if (following < limit && bytes[following] == 58) {
        if (depth == 0 ||
            containers[depth - 1] != 123 ||
            keyCount == maximumKeys) {
          return false;
        }
        final object = objects[depth - 1];
        for (var k = 0; k < keyCount; ++k) {
          if (keys[k * 3] != object || keys[k * 3 + 2] != count) continue;
          var same = true;
          for (var n = 0; n < count; ++n) {
            if (bytes[keys[k * 3 + 1] + n] != bytes[start + n]) {
              same = false;
              break;
            }
          }
          if (same) return false;
        }
        keys[keyCount * 3] = object;
        keys[keyCount * 3 + 1] = start;
        keys[keyCount * 3 + 2] = count;
        ++keyCount;
      }
      continue;
    }
    if (unit == 44 || unit == 58) {
      ++i;
      continue;
    }
    if (unit == 45 || (unit >= 48 && unit <= 57)) {
      final start = i++;
      while (i < limit && bytes[i] >= 48 && bytes[i] <= 57) {
        ++i;
      }
      if (i - start > 20) return false;
      continue;
    }
    final literal = unit == 116
        ? 'true'
        : unit == 102
        ? 'false'
        : unit == 110
        ? 'null'
        : null;
    if (literal == null || i + literal.length > limit) return false;
    for (var n = 0; n < literal.length; ++n) {
      if (bytes[i + n] != literal.codeUnitAt(n)) return false;
    }
    i += literal.length;
  }
  return depth == 0;
}
