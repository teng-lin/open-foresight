import 'dart:convert';
import 'operation_requests.dart';
import 'operations.dart';
import 'service_compatibility.dart';

/// Structural transport decoding precedes the closing refusal. Operation
/// decoding follows that refusal, before any capability or lifetime effect.
Map<String, dynamic> decodeServiceObject(String line) {
  final decoded = jsonDecode(line);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Invalid request');
  }
  return decoded;
}

class ServiceCallEnvelope {
  ServiceCallEnvelope.decode(Map<String, dynamic> frame) {
    final frameId = frame['id'];
    final frameMethod = frame['method'];
    final frameArguments = frame['args'];
    if (frameId is! int || frameMethod is! String || frameArguments is! Map) {
      throw const FormatException('Invalid request');
    }
    id = frameId;
    method = frameMethod;
    arguments = Map<String, dynamic>.from(frameArguments);
  }
  late final int id;
  late final String method;
  late final Map<String, dynamic> arguments;

  OperationRequest decodeOperation(String conversation) {
    final args = Map<String, dynamic>.of(arguments);
    args.putIfAbsent('conversation', () => conversation);
    args['requestId'] = 'rpc-$conversation-$id';
    final request = decodeOperationRequest(Operation.parse(method), args);
    if (request is StatusRequest) {
      validateApplicationClientVersion(request.clientApiVersion);
    }
    return request;
  }
}
