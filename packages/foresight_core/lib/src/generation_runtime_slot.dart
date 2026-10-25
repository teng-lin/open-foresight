import 'dart:async';
import 'dart:collection';

import 'cancellation.dart';

/// One owner for candidate, installed and retiring native runtime generations.
/// Revocation is synchronous; [drain] joins the actual producer and native close
/// completions, including candidates that return after losing their epoch.
final class GenerationRuntimeSlot<T extends Object> {
  GenerationRuntimeSlot({
    required this.closeRuntime,
    required this.runtimeClosed,
    required this.runtimeBusy,
    required this.changed,
    this.watchRuntime,
  });
  final void Function(T) closeRuntime;
  final Future<void> Function(T) runtimeClosed;
  final bool Function(T) runtimeBusy;
  final void Function() changed;
  final void Function(T, void Function())? watchRuntime;
  final _retirement = Expando<Future<void>>();
  final _candidates = HashSet<T>.identity();
  final _retiring = <Future<void>>{};
  final _producers = <Future<void>>{};
  T? _installed, _visibleCandidate;
  int _epoch = 0;
  bool _closed = false;
  Object? _failure;
  StackTrace? _failureStack;
  void _rememberFailure(Object error, StackTrace stack) {
    _failure ??= error;
    _failureStack ??= stack;
  }

  void _checkFailure() {
    final failure = _failure;
    if (failure != null) Error.throwWithStackTrace(failure, _failureStack!);
  }

  void _notify() {
    try {
      changed();
    } catch (error, stack) {
      _rememberFailure(error, stack);
    }
  }

  T? get installed => _installed;
  T? get visible => _installed ?? _visibleCandidate;
  bool get busy =>
      _failure != null ||
      _producers.isNotEmpty ||
      _retiring.isNotEmpty ||
      (_installed != null && runtimeBusy(_installed!));

  Future<void> retire(T runtime) {
    final existing = _retirement[runtime];
    if (existing != null) return existing;
    final completion = Future<void>.sync(() {
      closeRuntime(runtime);
      return runtimeClosed(runtime);
    });
    _retirement[runtime] = completion;
    _retiring.add(completion);
    _notify();
    void settled() {
      _retiring.remove(completion);
      _notify();
    }

    unawaited(
      completion.then<void>(
        (_) => settled(),
        onError: (Object error, StackTrace stack) {
          _rememberFailure(error, stack);
          settled();
        },
      ),
    );
    return completion;
  }

  void _invalidateCandidates() {
    _epoch++;
    _visibleCandidate = null;
    for (final candidate in _candidates.toList()) {
      unawaited(
        retire(
          candidate,
        ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  Future<T?> replace(
    Future<T?> Function(GenerationRuntimeAttempt<T>) produce, {
    bool Function()? current,
  }) async {
    if (_closed) throw operationCancelled();
    _checkFailure();
    final previousProducers = _producers.toList();
    _invalidateCandidates();
    final epoch = _epoch;
    final complete = Completer<void>();
    _producers.add(complete.future);
    final owned = HashSet<T>.identity();
    final attempt = GenerationRuntimeAttempt<T>._(
      () => !_closed && epoch == _epoch && (current?.call() ?? true),
      (runtime) {
        owned.add(runtime);
        _candidates.add(runtime);
        watchRuntime?.call(runtime, _notify);
        if (!_closed && epoch == _epoch) _visibleCandidate = runtime;
      },
      retire,
    );
    _notify();
    T? candidate;
    Object? failure;
    StackTrace? failureStack;
    try {
      await Future.wait(previousProducers);
      attempt.check();
      _checkFailure();
      candidate = await produce(attempt);
      if (candidate != null) attempt.own(candidate);
      attempt.check();
      final old = _installed;
      if (old != null && !identical(old, candidate) && candidate != null) {
        _installed = null;
        await retire(old);
        attempt.check();
      }
      if (candidate != null) {
        await Future.wait(_retiring.toList());
        attempt.check();
        _checkFailure();
        _installed = candidate;
        if (identical(_visibleCandidate, candidate)) _visibleCandidate = null;
        owned.remove(candidate);
        _candidates.remove(candidate);
      }
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      for (final runtime in owned) {
        try {
          await retire(runtime);
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
        _candidates.remove(runtime);
        if (identical(_visibleCandidate, runtime)) _visibleCandidate = null;
      }
      _producers.remove(complete.future);
      complete.complete();
      _notify();
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
    return candidate;
  }

  Future<void> reset() {
    _invalidateCandidates();
    final old = _installed;
    _installed = null;
    if (old != null) {
      unawaited(
        retire(old).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    _notify();
    return Future.wait<void>([
      ..._producers,
      ..._retiring,
    ]).then<void>((_) => _checkFailure());
  }

  void stop() {
    if (_closed) return;
    _closed = true;
    unawaited(reset().then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  Future<void> drain() async {
    while (_producers.isNotEmpty || _retiring.isNotEmpty) {
      try {
        await Future.wait<void>([..._producers, ..._retiring]);
      } catch (error, stack) {
        _rememberFailure(error, stack);
      }
    }
    _checkFailure();
  }

  /// Existing fixture assignment remains explicit and uses the same retirement
  /// owner. Production adoption goes through [replace].
  void installForTesting(T? runtime) {
    if (_closed) {
      if (runtime != null) retire(runtime).ignore();
      throw operationCancelled();
    }
    _invalidateCandidates();
    final old = _installed;
    _installed = runtime;
    if (runtime != null) watchRuntime?.call(runtime, _notify);
    if (old != null && !identical(old, runtime)) {
      unawaited(
        retire(old).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
    _notify();
  }
}

final class GenerationRuntimeAttempt<T extends Object> {
  GenerationRuntimeAttempt._(this.current, this._own, this.retire);
  final bool Function() current;
  final void Function(T) _own;
  final Future<void> Function(T) retire;
  void check() {
    if (!current()) throw operationCancelled();
  }

  void own(T runtime) {
    _own(runtime);
    check();
  }
}
