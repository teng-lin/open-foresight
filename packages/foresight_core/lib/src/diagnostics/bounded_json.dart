import 'dart:typed_data';

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
