import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _ProcessInfo extends Struct {
  @Array(12)
  external Array<Uint32> prefix;
  // Kernel-provided command/name storage is deliberately never inspected.
  @Array(48)
  external Array<Uint8> unreadNames;
  @Array(6)
  external Array<Uint32> suffix;
  @Uint64()
  external int seconds;
  @Uint64()
  external int microseconds;
}

final class _Event extends Struct {
  @Uint64()
  external int ident;
  @Int16()
  external int filter;
  @Uint16()
  external int flags;
  @Uint32()
  external int fflags;
  @Int64()
  external int data;
  external Pointer<Void> udata;
}

final class _Timespec extends Struct {
  @Int64()
  external int seconds;
  @Int64()
  external int nanoseconds;
}

typedef _PidInfoC = Int32 Function(Int32, Int32, Uint64, Pointer<Void>, Int32);
typedef _PidInfo = int Function(int, int, int, Pointer<Void>, int);
typedef _ChildrenC = Int32 Function(Int32, Pointer<Void>, Int32);
typedef _Children = int Function(int, Pointer<Void>, int);
typedef _QueueC = Int32 Function();
typedef _Queue = int Function();
typedef _EventsC =
    Int32 Function(
      Int32,
      Pointer<_Event>,
      Int32,
      Pointer<_Event>,
      Int32,
      Pointer<_Timespec>,
    );
typedef _Events =
    int Function(
      int,
      Pointer<_Event>,
      int,
      Pointer<_Event>,
      int,
      Pointer<_Timespec>,
    );
typedef _CloseC = Int32 Function(Int32);
typedef _Close = int Function(int);
typedef _UidC = Uint32 Function();
typedef _Uid = int Function();

/// Test-only peer observation. Never waits/reaps/signals a service or child,
/// reads argv/environment/paths, or changes a logger deadline.
final class DiagnosticChildExitProbe {
  DiagnosticChildExitProbe._(this.servicePid);

  static DiagnosticChildExitProbe start(int servicePid) {
    final probe = DiagnosticChildExitProbe._(servicePid);
    if (!Platform.isMacOS || servicePid <= 1 || servicePid > 0x7fffffff) {
      return probe;
    }
    try {
      probe._start();
    } catch (_) {
      probe._setupFailed = true;
      probe.close();
    }
    return probe;
  }

  final int servicePid;
  static const _exit = 0x80000000, _exitStatus = 0x04000000;
  late final _PidInfo _pidInfo;
  late final _Children _children;
  late final _Events _events;
  late final _Close _closeQueue;
  int _uid = -1, _queue = -1;
  Pointer<_ProcessInfo>? _info;
  Pointer<Int32>? _pids;
  Pointer<_Event>? _changes, _received;
  Pointer<_Timespec>? _immediate;
  Timer? _timer;
  (int, int, int)? _parentBirth;
  final Map<int, (int, int, int)> _registered = {};
  final List<Map<String, Object?>> _observations = [];
  bool _armed = false, _closed = false, _setupFailed = false;
  int _registrationFailures = 0, _identityRaces = 0, _capacityRefused = 0;

  void _start() {
    if (sizeOf<_ProcessInfo>() != 136 || sizeOf<_Event>() != 32) return;
    final system = DynamicLibrary.process();
    final proc = DynamicLibrary.open('/usr/lib/libproc.dylib');
    _pidInfo = proc.lookupFunction<_PidInfoC, _PidInfo>('proc_pidinfo');
    _children = proc.lookupFunction<_ChildrenC, _Children>(
      'proc_listchildpids',
    );
    _events = system.lookupFunction<_EventsC, _Events>('kevent');
    _closeQueue = system.lookupFunction<_CloseC, _Close>('close');
    _uid = system.lookupFunction<_UidC, _Uid>('geteuid')();
    _info = calloc<_ProcessInfo>();
    _pids = calloc<Int32>(16);
    _changes = calloc<_Event>();
    _received = calloc<_Event>(16);
    _immediate = calloc<_Timespec>();
    _parentBirth = _birth(servicePid);
    if (_parentBirth == null) {
      close();
      return;
    }
    _queue = system.lookupFunction<_QueueC, _Queue>('kqueue')();
    if (_queue < 0) {
      close();
      return;
    }
    _armed = true;
    _tick();
    if (!_closed) {
      _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        try {
          _tick();
        } catch (_) {
          _setupFailed = true;
          close();
        }
      });
    }
  }

  (int, int, int)? _birth(int pid) {
    final pointer = _info!;
    final count = _pidInfo(
      pid,
      3,
      0,
      pointer.cast<Void>(),
      sizeOf<_ProcessInfo>(),
    );
    if (count != sizeOf<_ProcessInfo>() ||
        pointer.ref.prefix[3] != pid ||
        pointer.ref.prefix[5] != _uid) {
      return null;
    }
    return (
      pointer.ref.prefix[4],
      pointer.ref.seconds,
      pointer.ref.microseconds,
    );
  }

  void _drain() {
    final count = _events(_queue, nullptr, 0, _received!, 16, _immediate!);
    if (count < 0) return;
    for (var i = 0; i < count; i++) {
      final event = (_received! + i).ref;
      if (!_registered.containsKey(event.ident) || event.fflags & _exit == 0) {
        continue;
      }
      final status = event.data & 0xffff;
      final statusKnown = event.fflags & _exitStatus != 0;
      final signal = status & 0x7f;
      if (_observations.length < 16) {
        _observations.add({
          'pid': event.ident,
          'statusKnown': statusKnown,
          'exitCode': statusKnown && signal == 0 ? (status >> 8) & 0xff : null,
          'signal': statusKnown && signal != 0 && signal != 0x7f
              ? signal
              : null,
        });
      }
    }
  }

  void _tick() {
    if (_closed || _queue < 0) return;
    _drain();
    if (_birth(servicePid) != _parentBirth) {
      _drain();
      close();
      return;
    }
    final count = _children(
      servicePid,
      _pids!.cast<Void>(),
      sizeOf<Int32>() * 16,
    );
    for (var i = 0; i < count && i < 16; i++) {
      final pid = _pids![i];
      if (pid <= 1 || _registered.containsKey(pid)) continue;
      if (_registered.length == 16) {
        _capacityRefused = (_capacityRefused + 1).clamp(0, 16);
        continue;
      }
      final before = _birth(pid);
      if (before == null || before.$1 != servicePid) continue;
      final change = _changes!.ref;
      change.ident = pid;
      change.filter = -5; // EVFILT_PROC.
      change.flags = 0x1 | 0x4 | 0x10; // ADD | ENABLE | ONESHOT.
      change.fflags = _exit | _exitStatus;
      change.data = 0;
      change.udata = nullptr;
      if (_events(_queue, _changes!, 1, nullptr, 0, _immediate!) < 0) {
        _registrationFailures = (_registrationFailures + 1).clamp(0, 16);
        continue;
      }
      if (_birth(pid) != before) {
        _identityRaces = (_identityRaces + 1).clamp(0, 16);
        change.flags = 0x2; // DELETE.
        _events(_queue, _changes!, 1, nullptr, 0, _immediate!);
        continue;
      }
      _registered[pid] = before;
    }
  }

  Map<String, Object?> get snapshot {
    try {
      _tick();
    } catch (_) {
      _setupFailed = true;
      close();
    }
    return {
      'supported': Platform.isMacOS,
      'armed': _armed,
      'setupFailed': _setupFailed,
      'registeredChildren': _registered.length,
      'registrationFailures': _registrationFailures,
      'identityRaces': _identityRaces,
      'capacityRefused': _capacityRefused,
      'children': [
        for (final value in _observations) Map<String, Object?>.of(value),
      ],
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (_queue >= 0) _closeQueue(_queue);
    _queue = -1;
    if (_info != null) calloc.free(_info!);
    if (_pids != null) calloc.free(_pids!);
    if (_changes != null) calloc.free(_changes!);
    if (_received != null) calloc.free(_received!);
    if (_immediate != null) calloc.free(_immediate!);
  }
}
