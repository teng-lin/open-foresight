import 'dart:async';

import '../model_gate.dart';
import '../rpc_error.dart';

/// Every feature retains its reservation through actual producer settlement,
/// including the gap between native children and after cancellation or clear.
/// Presentation maps may be cleared without releasing this resource ownership.
final class GenerationCoordinator
    implements ModelGate, GenerationReservationGate {
  GenerationCoordinator({
    required this.restoring,
    required this.generating,
    required this.recording,
    required this.closed,
    required this.yieldAutomatic,
  });

  final bool Function() restoring, generating, recording, closed;
  final Future<void> Function() yieldAutomatic;
  GenerationReservation? _reservation;
  bool _closed = false;

  bool get configuring => _reservation?.configuration ?? false;
  @override
  bool get modelBusy => configuring || restoring();
  @override
  bool get generationReserved =>
      _reservation != null && !_reservation!.configuration;
  bool get busy => modelBusy || generationReserved || generating();

  /// Callers revalidate their workspace/input snapshot after this await, before
  /// reserving and dispatching. The yield callback joins each automatic owner.
  Future<void> yieldToForeground() async {
    _checkOpen();
    await yieldAutomatic();
    _checkOpen();
  }

  GenerationReservation reserve(
    String owner, {
    required void Function() cancel,
  }) {
    _checkOpen();
    if (busy) {
      throw RpcError(RpcErrorCode.busy, 'Generation already in progress');
    }
    return _reservation = GenerationReservation._(this, owner, false, cancel);
  }

  GenerationReservation configure() {
    _checkOpen();
    if (busy || recording()) {
      throw RpcError(
        RpcErrorCode.busy,
        'Model configuration is busy while generation or recording is active',
      );
    }
    return _reservation = GenerationReservation._(
      this,
      'model-configuration',
      true,
      () {},
    );
  }

  void _checkOpen() {
    if (_closed || closed()) {
      throw RpcError(RpcErrorCode.unavailable, 'Application closed');
    }
  }

  /// Whether this exact producer still owns the reservation.
  bool owns(GenerationReservation reservation) =>
      identical(_reservation, reservation);

  void _settle(GenerationReservation reservation) {
    if (identical(_reservation, reservation)) _reservation = null;
    if (!reservation._settled.isCompleted) reservation._settled.complete();
  }

  /// Cancellation is a request. Only the feature's finally block settles its
  /// reservation after the child stream and cleanup have actually completed.
  void cancel() => _reservation?._cancel();

  Future<void> close() async {
    _closed = true;
    final reservation = _reservation;
    reservation?._cancel();
    await reservation?._settled.future;
  }
}

final class GenerationReservation {
  GenerationReservation._(
    this._coordinator,
    this.owner,
    this.configuration,
    this._cancel,
  );

  final GenerationCoordinator _coordinator;
  final String owner;
  final bool configuration;
  final void Function() _cancel;
  final _settled = Completer<void>();

  void settle() => _coordinator._settle(this);
}
