import 'dart:convert';
import 'dart:io';
import 'package:foresight_core/src/generated/rag_service.pbgrpc.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  test(
    'running original and port helpers encode controlled text identically',
    () async {
      final original = ClientChannel(
        InternetAddress(
          env['FORESIGHT_ORIGINAL_TOKENIZER_SOCKET']!,
          type: InternetAddressType.unix,
        ),
        port: 0,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      final port = ClientChannel(
        InternetAddress(
          env['FORESIGHT_PORT_TOKENIZER_SOCKET']!,
          type: InternetAddressType.unix,
        ),
        port: 0,
        options: const ChannelOptions(
          credentials: ChannelCredentials.insecure(),
        ),
      );
      final observed = <Map<String, Object?>>[];
      try {
        for (final text in [
          '  Hello world  ',
          '中文 你好世界😀',
          '',
          ' \n\t ',
          'A [Source:2] citation and café.',
        ]) {
          final request = EncodeRequest(text: text);
          final a = await RagServiceClient(original).encode(
            request,
            options: CallOptions(timeout: const Duration(seconds: 10)),
          );
          final b = await RagServiceClient(port).encode(
            request,
            options: CallOptions(timeout: const Duration(seconds: 10)),
          );
          observed.add({
            'text': text,
            'original_tokens': a.tokens.toList(),
            'port_tokens': b.tokens.toList(),
          });
        }
        final report = env['FORESIGHT_TOKENIZER_REPORT'];
        if (report != null)
          File(report).writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(observed),
          );
        for (final row in observed)
          expect(
            row['port_tokens'],
            row['original_tokens'],
            reason: 'Controlled text: ${row['text']}',
          );
      } finally {
        await original.shutdown();
        await port.shutdown();
      }
    },
    skip:
        env['FORESIGHT_ORIGINAL_TOKENIZER_SOCKET'] == null ||
        env['FORESIGHT_PORT_TOKENIZER_SOCKET'] == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
