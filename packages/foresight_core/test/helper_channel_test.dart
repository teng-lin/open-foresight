import 'package:foresight_test_support/test_paths.dart';
import 'dart:async';
import 'dart:io';

import 'package:foresight_core/src/helper_channel.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:grpc/grpc_connection_interface.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

class _Sink implements StreamSink<StreamMessage> {
  final messages = <StreamMessage>[];
  final _done = Completer<void>();
  bool reject = false;
  Object? closeError;

  @override
  Future<void> get done => _done.future;
  @override
  void add(StreamMessage event) {
    if (reject || _done.isCompleted) throw StateError('HTTP/2 sink closed');
    messages.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) => throw error;
  @override
  Future<void> addStream(Stream<StreamMessage> stream) async {
    await for (final message in stream) {
      add(message);
    }
  }

  @override
  Future<void> close() {
    if (closeError != null) return Future.error(closeError!);
    if (!_done.isCompleted) _done.complete();
    return done;
  }
}

class _RawStream extends TransportStream {
  final output = _Sink();
  final input = StreamController<StreamMessage>();
  int terminations = 0;
  @override
  int get id => 1;
  @override
  Stream<StreamMessage> get incomingMessages => input.stream;
  @override
  StreamSink<StreamMessage> get outgoingMessages => output;
  @override
  set onTerminated(void Function(int?) value) {}
  @override
  void terminate() {
    terminations++;
    output.closeError = null;
    unawaited(output.close());
    unawaited(input.close());
  }
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

class _PingService extends RagServiceBase {
  Map<String, String>? metadata;
  DateTime? deadline;
  DateTime? observedAt;

  @override
  Future<PingResponse> ping(ServiceCall call, PingRequest request) async {
    observedAt = DateTime.now();
    metadata = call.clientMetadata;
    deadline = call.deadline;
    return PingResponse(success: true, version: 'after-half-close');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'helper channel preserves Unix RPC metadata, deadlines and compression',
    () async {
      final directory = createTestTempDirectorySync('helper-channel-');
      final address = InternetAddress(
        '${directory.path}/helper.sock',
        type: InternetAddressType.unix,
      );
      final service = _PingService();
      final server = Server.create(
        services: [service],
        codecRegistry: CodecRegistry(codecs: [GzipCodec()]),
      );
      await server.serve(address: address, port: 0);
      final channel = HelperChannel(
        address,
        port: 0,
        options: ChannelOptions(
          credentials: const ChannelCredentials.insecure(
            authority: 'profile-helper',
          ),
          connectTimeout: const Duration(seconds: 2),
          codecRegistry: CodecRegistry(codecs: [GzipCodec()]),
        ),
      );
      try {
        final before = DateTime.now();
        final reply = await RagServiceClient(channel).ping(
          PingRequest(),
          options: CallOptions(
            timeout: const Duration(seconds: 3),
            metadata: {'x-probe': 'owned-writer'},
            compression: GzipCodec(),
          ),
        );
        expect(reply.success, isTrue);
        expect(reply.version, 'after-half-close');
        expect(service.metadata?['x-probe'], 'owned-writer');
        expect(service.metadata?[':authority'], 'profile-helper');
        expect(service.metadata?['grpc-encoding'], 'gzip');
        expect(service.metadata?['grpc-timeout'], '3000m');
        expect(service.deadline, isNotNull);
        expect(service.deadline!.isAfter(before), isTrue);
        // gRPC reconstructs the deadline when headers arrive. Connection and
        // event-loop startup before that point are not part of this timeout.
        expect(
          service.deadline!.difference(service.observedAt!).inMicroseconds,
          inInclusiveRange(0, const Duration(seconds: 3).inMicroseconds),
        );
      } finally {
        await channel.terminate();
        await server.shutdown();
        directory.deleteSync(recursive: true);
      }
    },
  );
  test('secure Unix channels reject an insecure server', () async {
    final directory = createTestTempDirectorySync('helper-secure-');
    final address = InternetAddress(
      '${directory.path}/helper.sock',
      type: InternetAddressType.unix,
    );
    final listener = await ServerSocket.bind(address, 0);
    final server = ConnectionServer([_PingService()]);
    final peers = <Socket>[];
    final connections = <ServerTransportConnection>[];
    final subscription = listener.listen((peer) {
      peers.add(peer);
      final connection = ServerTransportConnection.viaSocket(peer);
      connections.add(connection);
      unawaited(server.serveConnection(connection: connection));
    });
    final channel = HelperChannel(
      address,
      port: 0,
      options: const ChannelOptions(connectTimeout: Duration(seconds: 1)),
    );
    try {
      await expectLater(
        RagServiceClient(channel).ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(seconds: 2)),
        ),
        throwsA(isA<GrpcError>()),
      );
    } finally {
      await channel.terminate();
      for (final peer in peers) {
        peer.destroy();
      }
      for (final connection in connections) {
        await connection.terminate();
      }
      await subscription.cancel();
      await listener.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('Unix channels respect an unavailable configured proxy', () async {
    final directory = createTestTempDirectorySync('helper-proxy-');
    final address = InternetAddress(
      '${directory.path}/helper.sock',
      type: InternetAddressType.unix,
    );
    final server = Server.create(services: [_PingService()]);
    await server.serve(address: address, port: 0);
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = proxy.port;
    await proxy.close();
    final channel = HelperChannel(
      address,
      port: 0,
      options: ChannelOptions(
        credentials: const ChannelCredentials.insecure(),
        proxy: Proxy(host: '127.0.0.1', port: port),
        connectTimeout: const Duration(seconds: 1),
      ),
    );
    try {
      // The plaintext Unix endpoint is healthy, but this explicit proxy is not.
      await expectLater(
        RagServiceClient(channel).ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(seconds: 2)),
        ),
        throwsA(isA<GrpcError>()),
      );
    } finally {
      await channel.terminate();
      await server.shutdown();
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'peer EOF before a queued request reports failure without escaping',
    () async {
      final raw = _RawStream();
      final errors = <Object>[];
      final stream = HelperTransportStream(
        raw,
        (error, _) => errors.add(error),
        null,
        null,
      );
      stream.outgoingMessages.add([1, 2, 3]);
      await raw.output.close();
      await _pump();
      expect(errors, hasLength(1));
      expect(errors.single, isA<GrpcError>());
      expect((errors.single as GrpcError).code, StatusCode.unavailable);
      expect(raw.output.messages, isEmpty);
      await stream.terminate();
      expect(raw.terminations, 1);
    },
  );

  test(
    'synchronous write failure cancels queued data and permits reentrant cleanup',
    () async {
      final raw = _RawStream()..output.reject = true;
      final errors = <Object>[];
      late HelperTransportStream stream;
      Future<void>? cleanup;
      stream = HelperTransportStream(
        raw,
        (error, _) {
          errors.add(error);
          cleanup = stream.terminate();
        },
        null,
        null,
      );
      stream.outgoingMessages.add([1]);
      stream.outgoingMessages.add([2]);
      await _pump();
      expect(errors, hasLength(1));
      expect((errors.single as GrpcError).code, StatusCode.unavailable);
      expect(cleanup, same(stream.terminate()));
      await cleanup;
      expect(raw.output.messages, isEmpty);
      expect(raw.terminations, 1);
    },
  );

  test(
    'failed asynchronous HTTP/2 half-close reaches the request error handler',
    () async {
      final raw = _RawStream()..output.closeError = StateError('close failed');
      final errors = <Object>[];
      final stream = HelperTransportStream(
        raw,
        (error, _) => errors.add(error),
        null,
        null,
      );
      stream.outgoingMessages.add([1]);
      await stream.outgoingMessages.close();
      await _pump();
      expect(errors, hasLength(1));
      expect((errors.single as GrpcError).code, StatusCode.unavailable);
      await stream.terminate();
      expect(raw.terminations, 1);
    },
  );

  test(
    'request stream errors keep their gRPC status and cancel forwarding',
    () async {
      final raw = _RawStream();
      final errors = <Object>[];
      final stream = HelperTransportStream(
        raw,
        (error, _) => errors.add(error),
        null,
        null,
      );
      final error = GrpcError.cancelled('request cancelled');
      stream.outgoingMessages.addError(error);
      stream.outgoingMessages.add([1]);
      await _pump();
      expect(errors, [same(error)]);
      expect(raw.output.messages, isEmpty);
      await stream.terminate();
      expect(raw.terminations, 1);
    },
  );

  test(
    'normal request half-close preserves the later response and compression',
    () async {
      final raw = _RawStream();
      final errors = <Object>[];
      final stream = HelperTransportStream(
        raw,
        (error, _) => errors.add(error),
        null,
        GzipCodec(),
      );
      final response = stream.incomingMessages.toList();
      const request = [1, 2, 3];
      stream.outgoingMessages.add(request);
      await stream.outgoingMessages.close();
      await _pump();
      expect(raw.terminations, 0);
      final message = raw.output.messages.single as DataStreamMessage;
      expect(message.bytes, frame(request, GzipCodec()));
      raw.input.add(
        HeadersStreamMessage([
          Header.ascii(':status', '200'),
          Header.ascii('content-type', 'application/grpc'),
        ]),
      );
      raw.input.add(DataStreamMessage(frame([4, 5, 6])));
      raw.input.add(
        HeadersStreamMessage([
          Header.ascii('grpc-status', '0'),
        ], endStream: true),
      );
      await raw.input.close();
      final messages = await response;
      expect(messages.whereType<GrpcData>().single.data, [4, 5, 6]);
      expect(errors, isEmpty);
      await stream.terminate();
    },
  );

  test(
    'explicit cancellation stops queued writes and a new request succeeds',
    () async {
      final cancelled = _RawStream();
      final errors = <Object>[];
      final first = HelperTransportStream(
        cancelled,
        (error, _) => errors.add(error),
        null,
        null,
      );
      first.outgoingMessages.add([1]);
      final cleanup = first.terminate();
      expect(first.terminate(), same(cleanup));
      await cleanup;
      expect(cancelled.output.messages, isEmpty);
      expect(cancelled.terminations, 1);
      expect(errors, isEmpty);

      final next = _RawStream();
      final second = HelperTransportStream(
        next,
        (error, _) => errors.add(error),
        null,
        null,
      );
      second.outgoingMessages.add([2]);
      await second.outgoingMessages.close();
      expect(
        (next.output.messages.single as DataStreamMessage).bytes,
        frame([2]),
      );
      expect(errors, isEmpty);
      await second.terminate();
    },
  );
}
