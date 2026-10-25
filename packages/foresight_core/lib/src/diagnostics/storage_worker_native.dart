import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _UnaryNative = Int32 Function(Uint64);
typedef _Unary = int Function(int);
typedef _ReserveNative =
    Uint64 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint8>,
      Uint32,
      Uint32,
    );
typedef _Reserve =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint8>,
      int,
      int,
    );
typedef _ArmNative =
    Uint64 Function(Int64, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Arm = int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _OperationNative = Int32 Function(Uint64, Int32);
typedef _Operation = int Function(int, int);
typedef _SendNative =
    Int32 Function(Uint64, Uint8, Uint64, Uint32, Pointer<Uint8>, Uint32);
typedef _Send = int Function(int, int, int, int, Pointer<Uint8>, int);
typedef _ReceiveNative =
    Int32 Function(
      Uint64,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint32>,
    );
typedef _Receive =
    int Function(
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Uint32>,
    );

/// A function table from an already validated, early loaded system-only image.
///
/// This module never resolves or loads a path. Composition retains [image] for
/// the process lifetime before opening application files. Only these original
/// code addresses and a process-local opaque generation cross owned isolates;
/// no mapping, descriptor, application pointer or peer-supplied address does.
final class DiagnosticNativeFunctions {
  DiagnosticNativeFunctions.fromImage(DynamicLibrary image)
    : this._(
        List<int>.unmodifiable(
          _symbols.map((name) => image.lookup<Void>(name).address),
        ),
        image,
      );

  /// Internal owned-isolate bootstrap only. Never decode from worker IPC.
  DiagnosticNativeFunctions.fromCodeAddresses(List<int> addresses)
    : this._(_validatedAddresses(addresses), null);

  DiagnosticNativeFunctions._(this.codeAddresses, this.image);

  static const _symbols = [
    'fs_diag_parent_reserve',
    'fs_diag_parent_prepare',
    'fs_diag_parent_spawn',
    'fs_diag_parent_poll',
    'fs_diag_parent_force',
    'fs_diag_parent_heartbeat',
    'fs_diag_child_arm',
    'fs_diag_child_watch',
    'fs_diag_child_map',
    'fs_diag_child_operation',
    'fs_diag_support_send',
    'fs_diag_support_receive',
    'fs_diag_parent_exit_class',
    'fs_diag_child_finish',
  ];
  static const error = -1,
      prepared = 2,
      spawned = 8,
      notLive = 16,
      reaped = 32,
      cancelled = 64,
      failed = 128,
      watchBound = 256,
      empty = 0,
      partial = 1,
      complete = 2,
      exhausted = 3,
      chunkBytes = 4056;
  final List<int> codeAddresses;
  final DynamicLibrary? image;

  static List<int> _validatedAddresses(List<int> values) {
    if (values.length != _symbols.length ||
        values.any((value) => value <= 0 || value > 0x7fffffffffffffff)) {
      throw ArgumentError('Invalid owned diagnostic function table');
    }
    return List<int>.unmodifiable(values);
  }

  late final _reserve = Pointer<NativeFunction<_ReserveNative>>.fromAddress(
    codeAddresses[0],
  ).asFunction<_Reserve>();
  late final _prepare = _unary(1);
  late final _spawn = _unary(2);
  late final _poll = _unary(3);
  late final _force = _unary(4);
  late final _heartbeat = _unary(5);
  late final _arm = Pointer<NativeFunction<_ArmNative>>.fromAddress(
    codeAddresses[6],
  ).asFunction<_Arm>();
  late final _watch = _unary(7);
  late final _map = _unary(8);
  late final _exitClass = _unary(12);
  late final _finish = Pointer<NativeFunction<_OperationNative>>.fromAddress(
    codeAddresses[13],
  ).asFunction<_Operation>();
  late final _operation = Pointer<NativeFunction<_OperationNative>>.fromAddress(
    codeAddresses[9],
  ).asFunction<_Operation>();
  late final _send = Pointer<NativeFunction<_SendNative>>.fromAddress(
    codeAddresses[10],
  ).asFunction<_Send>();
  late final _receive = Pointer<NativeFunction<_ReceiveNative>>.fromAddress(
    codeAddresses[11],
  ).asFunction<_Receive>();

  _Unary _unary(int index) => Pointer<NativeFunction<_UnaryNative>>.fromAddress(
    codeAddresses[index],
  ).asFunction<_Unary>();

  int prepare(int id) => _prepare(id);
  int spawn(int id) => _spawn(id);
  int poll(int id) => _poll(id);
  int exitClass(int id) => _exitClass(id);
  int force(int id) => _force(id);
  int heartbeat(int id) => _heartbeat(id);
  int watch(int id) => _watch(id);
  int mapChild(int id) => _map(id);
  int finishChild(int id, int status) => _finish(id, status);
  int operation(int id, {required bool active}) =>
      _operation(id, active ? 1 : 0);

  int reserve({
    required String nativeId,
    required String dartId,
    required String catalogId,
    required List<String> arguments,
  }) {
    if (arguments.length < 4 || arguments.length > 16) {
      throw ArgumentError('Invalid diagnostic argument count');
    }
    final bytes = calloc<Uint8>(2048);
    try {
      final target = bytes.asTypedList(2048);
      var offset = 0;
      for (final argument in arguments) {
        if (argument.isEmpty ||
            argument.length > 1024 ||
            argument.contains('\u0000')) {
          throw ArgumentError('Invalid diagnostic argument');
        }
        final encoded = utf8.encode(argument);
        if (encoded.length > 1024 || offset + encoded.length + 1 > 2048) {
          throw ArgumentError('Diagnostic arguments exceed bound');
        }
        target.setRange(offset, offset + encoded.length, encoded);
        offset += encoded.length + 1;
      }
      return _identities(
        nativeId,
        dartId,
        catalogId,
        (native, dart, catalog) =>
            _reserve(native, dart, catalog, bytes, offset, arguments.length),
      );
    } finally {
      calloc.free(bytes);
    }
  }

  int armChild({
    required int parentPid,
    required String nativeId,
    required String dartId,
    required String catalogId,
  }) => _identities(
    nativeId,
    dartId,
    catalogId,
    (native, dart, catalog) => _arm(parentPid, native, dart, catalog),
  );

  static int _identities(
    String nativeId,
    String dartId,
    String catalogId,
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>) invoke,
  ) {
    final shape = RegExp(r'^[0-9a-f]{64}$');
    if (!shape.hasMatch(nativeId) ||
        !shape.hasMatch(dartId) ||
        !shape.hasMatch(catalogId)) {
      throw ArgumentError('Invalid diagnostic identity');
    }
    final native = nativeId.toNativeUtf8();
    final dart = dartId.toNativeUtf8();
    final catalog = catalogId.toNativeUtf8();
    try {
      return invoke(native, dart, catalog);
    } finally {
      malloc.free(catalog);
      malloc.free(dart);
      malloc.free(native);
    }
  }
}

/// One fixed chunk buffer per sole endpoint owner, not per event/request.
/// Payload bytes are copied before the next call; partial chunks may only be
/// accumulated within the fixed request/reply bounds by the protocol codec.
final class DiagnosticNativeEndpoint {
  DiagnosticNativeEndpoint(this.functions, this.id);
  final DiagnosticNativeFunctions functions;
  final int id;
  final _buffer = calloc<Uint8>(DiagnosticNativeFunctions.chunkBytes);
  final _copied = calloc<Uint32>();
  final _type = calloc<Uint8>();
  final _request = calloc<Uint64>();
  final _total = calloc<Uint32>();
  bool _closed = false;

  int send(int type, int request, int total, Uint8List chunk) {
    if (_closed) throw StateError('Closed diagnostic endpoint');
    if (chunk.length > DiagnosticNativeFunctions.chunkBytes ||
        type < 1 ||
        type > 9 ||
        request < 0 ||
        request > 0x7fffffffffffffff ||
        total < 0 ||
        total > 8192) {
      throw ArgumentError('Diagnostic frame exceeds bound');
    }
    _buffer.asTypedList(chunk.length).setAll(0, chunk);
    return functions._send(id, type, request, total, _buffer, chunk.length);
  }

  ({int result, int type, int request, int total, Uint8List bytes}) receive() =>
      _read(copy: true);

  /// Sole child decoder only: copy this view into its bounded assembly buffer
  /// synchronously before ANY next send/receive/close. It is invalidated by the
  /// next endpoint call. This avoids an extra live4KiB event copy during parse.
  ({int result, int type, int request, int total, Uint8List bytes})
  receiveBorrowed() => _read(copy: false);

  ({int result, int type, int request, int total, Uint8List bytes}) _read({
    required bool copy,
  }) {
    if (_closed) throw StateError('Closed diagnostic endpoint');
    final result = functions._receive(
      id,
      _buffer,
      DiagnosticNativeFunctions.chunkBytes,
      _copied,
      _type,
      _request,
      _total,
    );
    return (
      result: result,
      type: _type.value,
      request: _request.value,
      total: _total.value,
      bytes: copy
          ? Uint8List.fromList(_buffer.asTypedList(_copied.value))
          : _buffer.asTypedList(_copied.value),
    );
  }

  // Only after this isolate's synchronous send/receive has returned. Native
  // context/page lifetime is separate and remains process-long.
  void close() {
    if (_closed) return;
    _closed = true;
    calloc.free(_buffer);
    calloc.free(_copied);
    calloc.free(_type);
    calloc.free(_request);
    calloc.free(_total);
  }
}
