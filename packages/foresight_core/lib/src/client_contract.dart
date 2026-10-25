/// A provided null and an absent field have different v1 request identities.
/// Keep that distinction through typed construction and idempotent retries.
final class WireField<T> {
  const WireField(this.value) : present = true;
  const WireField.absent() : value = null, present = false;
  final T? value;
  final bool present;
}

final class ClientEnvelope {
  const ClientEnvelope({
    this.requestId = const WireField.absent(),
    this.conversation = const WireField.absent(),
    this.workspaceEpoch = const WireField.absent(),
    this.idempotencyKey = const WireField.absent(),
  });
  final WireField<String?> requestId,
      conversation,
      workspaceEpoch,
      idempotencyKey;

  Map<String, dynamic> attach(Map<String, dynamic> fields) => {
    ...fields,
    if (requestId.present) 'requestId': requestId.value,
    if (conversation.present) 'conversation': conversation.value,
    if (workspaceEpoch.present) 'workspace_epoch': workspaceEpoch.value,
    if (idempotencyKey.present) 'idempotency_key': idempotencyKey.value,
  };
}

abstract class ClientArguments {
  const ClientArguments({this.envelope = const ClientEnvelope()});
  final ClientEnvelope envelope;
  Map<String, dynamic> toWire();
}

abstract interface class ClientRequestEncoder<Q extends ClientArguments> {
  Map<String, dynamic> encode(Q request);
}

final class OperationInputEncoder<Q extends ClientArguments>
    implements ClientRequestEncoder<Q> {
  const OperationInputEncoder();
  @override
  Map<String, dynamic> encode(Q request) => request.toWire();
}

abstract interface class ClientResultDecoder<R> {
  R decode(Object? result);
}
