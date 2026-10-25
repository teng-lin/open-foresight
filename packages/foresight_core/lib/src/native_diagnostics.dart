import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_lifetime.dart';

final class _Record extends Struct {
  @Uint64()
  external int sequence;
  @Uint64()
  external int monotonicUs;
  @Uint16()
  external int event;
  @Uint16()
  external int component;
  @Uint16()
  external int category;
  @Uint16()
  external int outcome;
  @Int32()
  external int status;
  @Int32()
  external int signal;
  @Uint64()
  external int bytes;
  @Uint64()
  external int dropped;
  @Uint32()
  external int queued;
  @Uint32()
  external int active;
  @Uint64()
  external int durationUs;
}

final class _Batch extends Struct {
  @Uint32()
  external int abi;
  @Uint32()
  external int structureSize;
  @Uint32()
  external int count;
  @Uint32()
  external int flags;
  @Uint64()
  external int droppedGeneral;
  @Uint64()
  external int droppedPriority;
}

typedef _OpenNative = Int32 Function(Uint32, Uint32, Pointer<Uint64>);
typedef _Open = int Function(int, int, Pointer<Uint64>);
typedef _DrainNative =
    Int32 Function(
      Uint64,
      Uint32,
      Uint32,
      Pointer<_Record>,
      Uint32,
      Uint32,
      Pointer<_Batch>,
      Uint32,
    );
typedef _Drain =
    int Function(
      int,
      int,
      int,
      Pointer<_Record>,
      int,
      int,
      Pointer<_Batch>,
      int,
    );

/// Process-local code capabilities from one already loaded, verified image.
/// Only an owned isolate handoff may reconstruct these; never decode addresses
/// from files, environment, a socket or worker IPC.
final class NativeDiagnosticQueueFunctions {
  NativeDiagnosticQueueFunctions._(this.codeAddresses, this.image);
  static const _symbols = [
    'fs_diagnostic_abi_version',
    'fs_diagnostic_open',
    'fs_diagnostic_drain',
    'fs_diagnostic_close',
    'fs_lifetime_version',
    'fs_lifetime_admission',
  ];
  final List<int> codeAddresses;
  final DynamicLibrary? image;

  static NativeDiagnosticQueueFunctions? fromLoaded(NativeLibrary loaded) {
    final image = loaded.library;
    if (_symbols.any((name) => !image.providesSymbol(name))) return null;
    final functions = NativeDiagnosticQueueFunctions._(
      List<int>.unmodifiable(
        _symbols.map((name) => image.lookup<Void>(name).address),
      ),
      image,
    );
    return functions._compatible ? functions : null;
  }

  factory NativeDiagnosticQueueFunctions.fromPinnedCodeAddresses(
    List<int> values,
  ) {
    if (values.length != _symbols.length ||
        values.any((value) => value <= 0 || value > 0x7fffffffffffffff)) {
      throw ArgumentError('Invalid owned native diagnostic capabilities');
    }
    return NativeDiagnosticQueueFunctions._(
      List<int>.unmodifiable(values),
      null,
    );
  }

  int _constant(int at) =>
      Pointer<NativeFunction<Int32 Function()>>.fromAddress(
        codeAddresses[at],
      ).asFunction<int Function()>()();
  int get _queueVersion =>
      Pointer<NativeFunction<Uint32 Function()>>.fromAddress(
        codeAddresses[0],
      ).asFunction<int Function()>()();
  bool get _compatible =>
      _queueVersion == 1 &&
      _constant(4) == 2 &&
      sizeOf<_Record>() == 64 &&
      sizeOf<_Batch>() == 32;
  bool pin() => _compatible && _constant(5) == 1;
  bool configureLevel(String level) {
    final selected = image;
    if (selected == null ||
        !selected.providesSymbol('fs_set_runtime_environment')) {
      return false;
    }
    final configure = selected
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('fs_set_runtime_environment');
    final key = 'FORESIGHT_LOG_LEVEL'.toNativeUtf8();
    final value = level.toNativeUtf8();
    try {
      return configure(key, value) == 0;
    } finally {
      calloc.free(key);
      calloc.free(value);
    }
  }

  late final open = Pointer<NativeFunction<_OpenNative>>.fromAddress(
    codeAddresses[1],
  ).asFunction<_Open>();
  late final drain = Pointer<NativeFunction<_DrainNative>>.fromAddress(
    codeAddresses[2],
  ).asFunction<_Drain>();
  late final close =
      Pointer<NativeFunction<Int32 Function(Uint64)>>.fromAddress(
        codeAddresses[3],
      ).asFunction<int Function(int)>();
}

/// Closed numeric native values, validated before a diagnostic catalog adapter
/// may encode them. No raw strings, application handles or native pointers.
/// [sequence] carries unsigned 64-bit bits in a Dart int and can be negative;
/// it is a native lane watermark, separate from the final writer sequence.
final class NativeDiagnosticRecord {
  NativeDiagnosticRecord._(_Record value)
    : sequence = value.sequence,
      monotonicUs = value.monotonicUs,
      event = value.event,
      category = value.category,
      outcome = value.outcome,
      status = value.status,
      signal = value.signal,
      bytes = value.bytes,
      dropped = value.dropped,
      queued = value.queued,
      active = value.active != 0,
      durationUs = value.durationUs;
  final int sequence, monotonicUs, event, category, outcome, status, signal;
  final int bytes, dropped, queued, durationUs;
  final bool active;
  bool get priority => event == 1;
}

/// Counters are lower bounds if [precisionLost] or [counterSaturated]. Unsigned
/// 64-bit saturation maps to a negative Dart int; clamping to the catalog's safe
/// counter limit also sets [counterSaturated].
final class NativeDiagnosticBatch {
  NativeDiagnosticBatch._(_Batch value, this.deliveryDropped)
    : droppedGeneral = _counter(value.droppedGeneral),
      droppedPriority = _counter(value.droppedPriority),
      precisionLost = value.flags & 1 != 0,
      counterSaturated =
          value.flags & 2 != 0 ||
          _clamped(value.droppedGeneral) ||
          _clamped(value.droppedPriority),
      count = value.count;
  final int count, droppedGeneral, droppedPriority, deliveryDropped;
  final bool precisionLost, counterSaturated;
  static int _counter(int value) =>
      value < 0 ? 0x7fffffff : value.clamp(0, 0x7fffffff);
  static bool _clamped(int value) => value < 0 || value > 0x7fffffff;
}

/// A consumer of an already loaded original native image. It never opens a
/// library path, creates handles, changes severity or starts a timer. The
/// lifetime admission pins this actual image before queue registration.
///
/// The caller reserves writer credits before [poll] and drives it on its
/// existing logging tick. Keep this owner until [close] succeeds. A BUSY close
/// retains its token and fixed buffers and must be retried on a later tick.
final class NativeDiagnosticQueue {
  NativeDiagnosticQueue._(
    this._functions,
    this._token,
    this._records,
    this._batch,
  );

  static const maximumRecords = 64, nativeBufferBytes = 4096 + 32;
  final NativeDiagnosticQueueFunctions _functions;
  final Pointer<_Record> _records;
  final Pointer<_Batch> _batch;
  int _token, _normalSequence = 0, _prioritySequence = 0;
  bool _polling = false, _invalid = false;
  bool get closed => _token == 0;
  bool get invalid => _invalid;

  /// Unsupported optional diagnostics disable only this consumer. They do not
  /// alter the required runtime's pre-logging configuration/startup contract.
  static NativeDiagnosticQueue? tryOpen(NativeLibrary loaded) {
    final functions = NativeDiagnosticQueueFunctions.fromLoaded(loaded);
    if (functions == null || !functions.pin()) return null;
    return tryOpenPinned(functions);
  }

  /// The owner pins the original image BEFORE publishing its code addresses.
  /// The writer does not enter the native resource registry or loader here.
  static NativeDiagnosticQueue? tryOpenPinned(
    NativeDiagnosticQueueFunctions functions,
  ) {
    if (!functions._compatible) return null;
    final token = calloc<Uint64>();
    Pointer<_Record> records = nullptr;
    Pointer<_Batch> batch = nullptr;
    var transferred = false;
    try {
      records = calloc<_Record>(maximumRecords);
      batch = calloc<_Batch>();
      if (functions.open(1, 64, token) != 0 || token.value == 0) return null;
      final owner = NativeDiagnosticQueue._(
        functions,
        token.value,
        records,
        batch,
      );
      transferred = true;
      return owner;
    } finally {
      if (!transferred) {
        calloc.free(records);
        calloc.free(batch);
      }
      calloc.free(token);
    }
  }

  /// Call only with authority for [capacity] worst-case records. Priority-only
  /// polls preserve older ordinary records. The callback executes synchronously
  /// after the native call and cannot reenter/close this owner mid-batch. False
  /// or a thrown callback counts as delivery loss; no callback error escapes.
  NativeDiagnosticBatch? poll({
    required int capacity,
    required bool priorityOnly,
    required bool Function(NativeDiagnosticRecord) onRecord,
  }) {
    if (capacity < 1 || capacity > maximumRecords) {
      throw RangeError.range(capacity, 1, maximumRecords);
    }
    if (closed || _polling || _invalid) return null;
    _polling = true;
    try {
      final result = _functions.drain(
        _token,
        1,
        64,
        _records,
        capacity,
        priorityOnly ? 1 : 0,
        _batch,
        32,
      );
      if (result == -2) return null;
      if (result != 0 ||
          _batch.ref.abi != 1 ||
          _batch.ref.structureSize != 32 ||
          _batch.ref.count > capacity ||
          _batch.ref.flags & ~3 != 0) {
        _invalid = true;
        return null;
      }
      // Validate the entire bounded batch before exposing any record. Keep
      // separate lane watermarks: priority may overtake older ordinary data.
      var normal = _normalSequence, priority = _prioritySequence;
      for (var at = 0; at < _batch.ref.count; at++) {
        final value = _records[at];
        final isPriority = value.event == 1;
        if (!_valid(value) ||
            (priorityOnly && !isPriority) ||
            !_after(value.sequence, isPriority ? priority : normal)) {
          _invalid = true;
          return null;
        }
        if (isPriority) {
          priority = value.sequence;
        } else {
          normal = value.sequence;
        }
      }
      _normalSequence = normal;
      _prioritySequence = priority;
      var deliveryDropped = 0;
      for (var at = 0; at < _batch.ref.count; at++) {
        try {
          if (!onRecord(NativeDiagnosticRecord._(_records[at]))) {
            deliveryDropped++;
          }
        } catch (_) {
          deliveryDropped++;
        }
      }
      return NativeDiagnosticBatch._(_batch.ref, deliveryDropped);
    } finally {
      _polling = false;
    }
  }

  static bool _number(int value) => value >= 0 && value <= 9007199254740991;
  static bool _after(int value, int previous) =>
      value != 0 &&
      (value < 0 && previous >= 0 ||
          (value < 0) == (previous < 0) && value > previous);
  static bool _valid(_Record value) {
    if (!_number(value.monotonicUs) ||
        value.category > 11 ||
        value.outcome > 8) {
      return false;
    }
    return switch (value.event) {
      1 =>
        value.component == 5 &&
            _number(value.bytes) &&
            _number(value.dropped) &&
            value.queued == 0 &&
            value.active == 0 &&
            value.durationUs == 0,
      2 =>
        value.component == 6 &&
            value.status == 0 &&
            value.signal == 0 &&
            value.bytes == 0 &&
            value.dropped == 0 &&
            value.active <= 1 &&
            _number(value.durationUs),
      _ => false,
    };
  }

  bool close() {
    if (closed) return true;
    if (_polling) return false;
    // Keep the original mapped image strongly owned through the final call.
    if (_functions.close(_token) != 0) {
      return false;
    }
    _token = 0;
    calloc.free(_records);
    calloc.free(_batch);
    return true;
  }
}
