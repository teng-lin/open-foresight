import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:foresight_core/src/audio_models.dart';
import 'package:foresight_core/src/durable_capture.dart';
import 'package:foresight_core/src/persistence/backup_files.dart';
import 'package:foresight_core/src/persistence/recording_media.dart';
import 'package:foresight_core/src/recording_capture.dart';
import 'package:test/test.dart';

// Controlled native-route capability for service/storage tests. Actual native
// acquisition/IO fences are separately exercised by native_recording_capture.
final class CapturePlatformFixture implements DurableCapturePlatform {
  CapturePlatformFixture(this.media, {this.prepared, this.onCreated});
  final RecordingMedia media;
  final void Function(int)? prepared;
  final void Function(CaptureRouteFixture)? onCreated;
  int clock = 1000000;
  final routes = <CaptureRouteFixture>[];
  Completer<void>? admission;
  @override
  int monotonicUs() => clock;
  @override
  Future<DurableCaptureRoute> start({
    required String target,
    required AudioSource source,
    required String directory,
    required String sessionId,
    required String generation,
    required int span,
    required int originUs,
    required int sourceSample,
    required List<AudioChunkPublication> reservations,
    required bool Function() mayStart,
    required bool echoCancellation,
  }) async {
    prepared?.call(span);
    for (final id in reservations) {
      expect(media.audio.publication(id.id), isNotNull);
    }
    await admission?.future;
    if (!mayStart()) throw StateError('late device admission refused');
    final route = CaptureRouteFixture(
      media,
      source,
      span,
      sourceSample,
      reservations,
    );
    routes.add(route);
    onCreated?.call(route);
    return route;
  }
}

final class CaptureRouteFixture implements DurableCaptureRoute {
  CaptureRouteFixture(
    this.media,
    this.source,
    this.span,
    this.samples,
    List<AudioChunkPublication> ids,
  ) : reservations = List.of(ids);
  final RecordingMedia media;
  final AudioSource source;
  final int span;
  final List<AudioChunkPublication> reservations;
  final used = <String>{};
  final notices = <RecordingChunkNotice>[],
      finalNotices = <RecordingChunkNotice>[];
  final events = <Map<String, dynamic>>[];
  final log = <String>[];
  int samples;
  int? through, voice;
  bool finished = false, retired = false;
  bool rejectRetire = false, rejectFinish = false;
  String? error;
  Completer<void>? finishHold, reserveHold;
  double volume = 0;
  int lastBatch = -1;
  int get remaining => reservations.length - used.length;
  @override
  RecordingCaptureSnapshot poll() {
    final batch = List.of(notices);
    notices.clear();
    lastBatch = batch.length;
    log.add(finished ? 'poll-after-finish:${batch.length}' : 'poll');
    final first = reservations.first;
    return RecordingCaptureSnapshot.fromJson({
      'version': 1,
      'ready': true,
      'session_id': first.sessionId,
      'generation': first.storageGeneration,
      'source': source.index,
      'span': span,
      'state': error != null
          ? 'failed'
          : finished
          ? 'sealed'
          : through == null
          ? 'starting'
          : 'capturing',
      'capture_active': !finished && through != null && error == null,
      'error': error,
      'clock_quality': through == null ? 'unavailable' : 'hardware_host_time',
      'uncertainty_us': null,
      'source_sample': samples,
      'acquired_through_us': through,
      'queued_frames': 0,
      'reserved_chunks': remaining,
      'ready_chunks': batch.length,
      'outstanding_chunks': remaining + batch.length,
      'current_volume': volume,
      'peak_volume': volume,
      'last_voice_capture_us': voice,
      'chunks': [for (final notice in batch) json(notice)],
    });
  }

  static Map<String, dynamic> json(RecordingChunkNotice n) => {
    'chunk_id': n.chunkId,
    'session_id': n.sessionId,
    'generation': n.generation,
    'source': n.source.index,
    'sequence': n.sequence,
    'span': n.span,
    'source_sample': n.sourceSample,
    'frames': n.frames,
    'sample_rate': 48000,
    'channels': 1,
    'capture_start_us': n.captureStartUs,
    'bytes': n.byteLength,
    'relative_path': '${n.chunkId}.wav',
    'interrupted': n.interrupted,
    'gap_before': n.gapBefore,
    'contents_synced': true,
    'directory_synced': true,
  };
  RecordingChunkNotice audio(
    int start, {
    int frames = 4800,
    bool finalOnly = false,
    bool corrupt = false,
    bool voiced = false,
    bool gap = false,
    int? voiceFrames,
    int marker = 411,
  }) {
    final id = reservations.firstWhere((id) => !used.contains(id.id));
    used.add(id.id);
    final notice = RecordingChunkNotice.fromJson({
      'chunk_id': id.id,
      'session_id': id.sessionId,
      'generation': id.storageGeneration,
      'source': source.index,
      'sequence': id.sequence,
      'span': span,
      'source_sample': samples,
      'frames': frames,
      'sample_rate': 48000,
      'channels': 1,
      'capture_start_us': start,
      'bytes': 196 + frames * 2,
      'relative_path': '${id.id}.wav',
      'interrupted': false,
      'gap_before': gap,
      'contents_synced': true,
      'directory_synced': true,
    });
    samples += frames;
    through = notice.captureEndUs;
    if (voiced) {
      voice = start + (voiceFrames ?? frames) * 1000000 ~/ 48000;
      volume = .1;
    } else {
      volume = 0;
    }
    final bytes = Uint8List(notice.byteLength);
    final data = ByteData.sublistView(bytes);
    void text(int at, String s) =>
        bytes.setRange(at, at + s.length, ascii.encode(s));
    void u16(int at, int v) => data.setUint16(at, v, Endian.little);
    void u32(int at, int v) => data.setUint32(at, v, Endian.little);
    void u64(int at, int v) => data.setUint64(at, v, Endian.little);
    text(0, 'RIFF');
    u32(4, bytes.length - 8);
    text(8, 'WAVEfmt ');
    u32(16, 16);
    u16(20, 1);
    u16(22, 1);
    u32(24, 48000);
    u32(28, 96000);
    u16(32, 2);
    u16(34, 16);
    text(36, 'fsid');
    u32(40, 144);
    text(44, id.sessionId);
    text(80, id.storageGeneration);
    text(116, id.id);
    u32(152, source.index | (gap ? 0x40000000 : 0));
    u64(156, id.sequence);
    u64(164, span);
    u64(172, notice.sourceSample);
    u64(180, start);
    text(188, 'data');
    u32(192, frames * 2);
    for (var i = 0; i < 196; i++) {
      if (data.getUint8(i) != 0) bytes[i] = data.getUint8(i);
    }
    if (voiced) {
      for (var index = 0; index < (voiceFrames ?? frames); ++index) {
        data.setInt16(196 + index * 2, marker, Endian.little);
      }
    }
    if (corrupt) bytes[0] = 0;
    final dir = BackupDirectory(
      media.sessionDirectory(id.sessionId),
      create: false,
    );
    try {
      final file = dir.open('${id.id}.wav', create: true);
      try {
        file.write(bytes);
        file.sync();
      } finally {
        file.close();
      }
      dir.sync();
    } finally {
      dir.close();
    }
    (finalOnly ? finalNotices : notices).add(notice);
    return notice;
  }

  @override
  Map<String, dynamic>? pollEvent() =>
      events.isEmpty ? null : events.removeAt(0);
  @override
  int setEchoCancellation(bool enabled) => 1;
  @override
  Future<void> reserve(List<AudioChunkPublication> values) async {
    for (final id in values) {
      expect(media.audio.publication(id.id), isNotNull);
    }
    await reserveHold?.future;
    reservations.addAll(values);
  }

  @override
  Future<void> finish() async {
    log.add('finish-request');
    if (rejectFinish) throw StateError('finish ownership unconfirmed');
    await finishHold?.future;
    notices.addAll(finalNotices);
    finalNotices.clear();
    finished = true;
    log.add('finish-ack');
  }

  @override
  Future<void> retire() async {
    expect(finished, isTrue);
    expect(lastBatch, 0);
    log.add('retire');
    if (rejectRetire) throw StateError('retirement ownership unconfirmed');
    retired = true;
  }
}
