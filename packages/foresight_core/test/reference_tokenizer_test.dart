import 'dart:async';
import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

class TokenizerFixture extends RagServiceBase {
  final texts = <String>[];
  Future<EncodeResponse> Function(String) respond = (_) async =>
      EncodeResponse(tokens: [-1, 9, 9]);
  @override
  Future<EncodeResponse> encode(ServiceCall call, EncodeRequest request) {
    texts.add(request.text);
    return respond(request.text);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Server server;
  late ClientChannel channel;
  late TokenizerFixture fixture;
  late ReferenceRemoteTokenizer tokenizer;
  setUp(() async {
    fixture = TokenizerFixture();
    server = Server.create(services: [fixture]);
    await server.serve(address: '127.0.0.1', port: 0);
    channel = ClientChannel(
      '127.0.0.1',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    tokenizer = ReferenceRemoteTokenizer(RagServiceClient(channel));
  });
  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
  });

  test(
    'Encode preserves raw text and counts returned IDs without alteration',
    () async {
      expect(await tokenizer.count('  中文 😀\n '), 3);
      expect(fixture.texts, ['  中文 😀\n ']);
      fixture.respond = (_) async => EncodeResponse();
      expect(await tokenizer.count(''), 0);
      expect(fixture.texts.last, '');
    },
  );

  test(
    'bound tokenizer failures propagate instead of using a word estimate',
    () async {
      fixture.respond = (_) async =>
          throw const GrpcError.unavailable('Controlled failure');
      await expectLater(tokenizer.count('Question'), throwsA(isA<GrpcError>()));
    },
  );

  test('cancellation interrupts an unfinished Encode RPC', () async {
    final entered = Completer<void>(), release = Completer<void>();
    fixture.respond = (_) async {
      entered.complete();
      await release.future;
      return EncodeResponse(tokens: [1]);
    };
    var current = true;
    final pending = tokenizer.count(
      'Question',
      checkCurrent: () {
        if (!current) throw StateError('Cancelled');
      },
    );
    await entered.future;
    current = false;
    try {
      await expectLater(
        pending.timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
    } finally {
      release.complete();
    }
  });
}
