import 'client_contract.dart';
import 'operation_descriptor.dart';
import 'operations.dart';
import 'rpc_error.dart';
import 'pending_request_key.dart';

/// The existing transport owns workspace scoping, retries and caller lifetime.
abstract interface class ClientCommandPort {
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> arguments = const {},
  ]);
}

abstract interface class CurrentClientCommandPort implements ClientCommandPort {
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> arguments,
    bool Function() current,
  );
}

/// Request and result types derive from the contract receiver, independently of
/// method arguments. An unrelated request cannot widen inference to Object.
extension OperationClientCalls<Q extends ClientArguments, R>
    on OperationDescriptor<Q, R> {
  Operation get _operation => Operation.values.singleWhere(
    (candidate) => identical(candidate.descriptor, this),
  );

  Map<String, dynamic> _encode(Q request) {
    final encoded = requestEncoder.encode(request);
    // Validate through the service's schema without inserting its defaults or
    // replacing original strings, nulls or field presence before fingerprinting.
    arguments.decode(encoded);
    return encoded;
  }

  R decodeResponse(Object? value) {
    try {
      return resultDecoder.decode(value);
    } catch (_) {
      // A malformed reply follows a sent request. It cannot authorize a new
      // write or release a pending idempotency key as a definite rejection.
      throw RpcError(
        RpcErrorCode.internal,
        'The service returned an invalid response; the operation may have completed.',
        reason: RpcErrorReason.outcomeUnknown,
      );
    }
  }

  Future<R> send(ClientCommandPort owner, Q request) async =>
      decodeResponse(await owner.command(_operation, _encode(request)));

  Future<R> sendCurrent(
    CurrentClientCommandPort owner,
    Q request,
    bool Function() current,
  ) async => decodeResponse(
    await owner.commandCurrent(_operation, _encode(request), current),
  );

  /// Use the existing retry owner. Captured send-only envelope fields stay
  /// outside its argument-comparison ledger, as they do for legacy callbacks.
  Future<R> sendKeyed(
    PendingRequestKey pending,
    ClientCommandPort owner,
    Q request, {
    ClientEnvelope sendEnvelope = const ClientEnvelope(),
    bool Function()? current,
    Future<R> Function(R first, Q edited)? amend,
  }) async {
    final result = await pending.run(
      _encode(request),
      (keyed) async {
        final wire = sendEnvelope.attach(keyed);
        final Object? reply;
        if (current == null) {
          reply = await owner.command(_operation, wire);
        } else {
          reply = await (owner as CurrentClientCommandPort).commandCurrent(
            _operation,
            wire,
            current,
          );
        }
        return decodeResponse(reply);
      },
      amend: amend == null ? null : (first, _) => amend(first as R, request),
    );
    return result as R;
  }
}
