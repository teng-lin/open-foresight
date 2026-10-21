import 'dart:convert';
import 'dart:typed_data';

const maxServiceMessage = 16 * 1024 * 1024;
// Clients up to v0.1.2 counted bytes per socket read, not per frame, so a
// frame at their limit followed by more bytes in the same read failed. Current
// clients count each frame exactly; keep frames 1 MiB under the limit for the
// released ones.
const maxServiceFrame = maxServiceMessage - 1024 * 1024;

/// Splits a byte stream into newline-terminated frames. Each frame is counted
/// exactly: with its newline it may be at most [limit] bytes. Bytes after the
/// last newline are held until it arrives; they never form a frame.
class ServiceFrameSplitter {
  ServiceFrameSplitter(this.limit);
  final int limit;
  final _partial = BytesBuilder(copy: false);

  /// Whether bytes of an unfinished frame are held.
  bool get hasPartial => _partial.isNotEmpty;

  /// The frames [chunk] completes, without newlines, or null as soon as a
  /// frame exceeds [limit].
  List<Uint8List>? add(Uint8List chunk) {
    final frames = <Uint8List>[];
    var start = 0;
    while (true) {
      final end = chunk.indexOf(10, start);
      final length = (end < 0 ? chunk.length : end) - start;
      if (_partial.length + length + 1 > limit) return null;
      _partial.add(Uint8List.sublistView(chunk, start, start + length));
      if (end < 0) return frames;
      frames.add(_partial.takeBytes());
      start = end + 1;
    }
  }
}

/// A complete frame that is a JSON object, or null for any other frame.
Map<String, dynamic>? decodeServiceFrame(Uint8List frame) {
  try {
    final value = jsonDecode(utf8.decode(frame));
    return value is Map<String, dynamic> ? value : null;
  } on FormatException {
    return null;
  }
}
