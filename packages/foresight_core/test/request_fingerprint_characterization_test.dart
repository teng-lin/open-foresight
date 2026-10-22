import 'package:foresight_core/src/application.dart';
import 'package:test/test.dart';

void main() {
  test(
    'persisted argument fingerprint excludes only transport and null map fields',
    () {
      expect(
        requestArgumentsDigest({
          'z': [
            {'b': 2, 'a': 1, 'null': null},
            null,
          ],
          'a': {'omega': true, 'alpha': 'x'},
          'requestId': 'connection-owned',
          'conversation': 'reconnected',
          'workspace_epoch': 'new-envelope',
          'idempotency_key': 'same-key',
          'ignored': null,
        }),
        'e4ad78c5f865263536015f80a367624f94a0c9438d41e8ebcee9076fcbf633f5',
      );
    },
  );

  test(
    'unknown additive arguments and explicit defaults remain part of the key',
    () {
      final original = {'title': 'Draft', 'body': ''};
      final digest = requestArgumentsDigest(original);
      expect(
        digest,
        'e0f34aef687eccd808cb51ab22b951ef46b8c4da962b0b860dda9d875cfaf19f',
      );
      expect(requestArgumentsDigest({...original, 'id': null}), digest);
      expect(
        requestArgumentsDigest({...original, 'index': true}),
        isNot(digest),
      );
      expect(
        requestArgumentsDigest({...original, 'future_field': 'v1'}),
        isNot(digest),
      );
      expect(original, {'title': 'Draft', 'body': ''});
    },
  );

  test(
    'JSON integer and decimal spellings have distinct persisted fingerprints',
    () {
      expect(
        requestArgumentsDigest({'value': 1}),
        '48208f9428d64634bd8e28ff345bf0eab60d53c18fa2fbdb0b9bc1e84df2b5f6',
      );
      expect(
        requestArgumentsDigest({'value': 1.0}),
        '3a7d647740ec6f86b72e0bf3948ab456551e07e9605e3a2785de1c66842ebb48',
      );
    },
  );
}
