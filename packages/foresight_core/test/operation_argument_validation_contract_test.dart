import 'package:foresight_core/src/operation_argument_schema.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

Matcher invalidField(String name) => throwsA(
  isA<RpcError>()
      .having((error) => error.code, 'code', RpcErrorCode.invalidArgument)
      .having((error) => error.message, 'field', startsWith('$name ')),
);

void main() {
  test(
    'string constraints reject invalid requests at the declared boundary',
    () {
      const schema = OperationArgumentSchema([
        ArgumentField(
          'action',
          ArgumentKind.string,
          minimumLength: 3,
          maximumLength: 6,
          choices: ['start', 'stop'],
          description: 'Requested lifecycle action',
        ),
        ArgumentField('count', ArgumentKind.integer, minimum: 1, maximum: 3),
      ]);
      for (final action in ['no', 'restart', 'pause']) {
        expect(
          () => schema.decode({'action': action, 'count': 1}),
          invalidField('action'),
        );
      }
      for (final action in ['start', 'stop']) {
        expect(
          schema.decode({'action': action, 'count': 3}).value<String>('action'),
          action,
        );
      }
      final published = schema.schema.toJson();
      expect(published['required'], ['action', 'count']);
      expect(published['additionalProperties'], isTrue);
      expect((published['properties'] as Map)['action'], {
        'type': 'string',
        'minLength': 3,
        'maxLength': 6,
        'enum': ['start', 'stop'],
        'description': 'Requested lifecycle action',
      });
      expect((published['properties'] as Map)['count'], {
        'type': 'integer',
        'minimum': 1,
        'maximum': 3,
      });
    },
  );

  test('ISO date decoding rejects invalid values and retains the instant', () {
    const field = ArgumentField('starts', ArgumentKind.dateTime);
    for (final value in [123, 'not-a-date']) {
      expect(() => field.decode({'starts': value}), invalidField('starts'));
    }
    expect(
      field.decode({'starts': '2026-10-21T12:30:00+02:00'}),
      DateTime.utc(2026, 10, 21, 10, 30),
    );
  });

  test('list schema advertises the bounds and uniqueness it enforces', () {
    const field = ArgumentField(
      'sources',
      ArgumentKind.strings,
      minimumItems: 1,
      maximumItems: 2,
      distinct: true,
    );
    const schema = OperationArgumentSchema([field]);
    expect((schema.schema.toJson()['properties'] as Map)['sources'], {
      'type': 'array',
      'items': {'type': 'string'},
      'minItems': 1,
      'maxItems': 2,
      'uniqueItems': true,
    });
    for (final sources in [
      <String>[],
      ['duplicate', 'duplicate'],
      ['one', 'two', 'three'],
    ]) {
      expect(
        () => schema.decode({'sources': sources}),
        invalidField('sources'),
      );
    }
    for (final sources in [
      ['one'],
      ['one', 'two'],
    ]) {
      final values = schema
          .decode({'sources': sources})
          .value<List<String>>('sources');
      expect(values, sources);
      expect(() => values.add('three'), throwsUnsupportedError);
    }
  });

  test(
    'published graph and optional-field schema matches decoder exposure',
    () {
      const schema = OperationArgumentSchema([
        ArgumentField('sources', ArgumentKind.graphSources),
        ArgumentField('vectors', ArgumentKind.vectors),
        ArgumentField('points', ArgumentKind.points),
        ArgumentField('clusters', ArgumentKind.clusters, nullable: true),
        ArgumentField('labels', ArgumentKind.strings, defaultValue: <String>[]),
        ArgumentField('enabled', ArgumentKind.trueSwitch),
      ]);
      final published = schema.schema.toJson();
      expect(published['required'], ['sources', 'vectors', 'points']);
      final properties = published['properties'] as Map;
      expect(properties['sources'], {
        'type': 'array',
        'items': {'type': 'object', 'additionalProperties': true},
      });
      expect(properties['clusters'], properties['sources']);
      expect(properties['vectors'], {'type': 'object'});
      expect(properties['points'], {'type': 'object'});
      expect(properties['labels'], {
        'type': 'array',
        'items': {'type': 'string'},
      });
      expect(properties['enabled'], {'type': 'boolean'});
      expect(
        () => schema.decode({
          'sources': [
            <Object?, Object?>{'id': 'source', 1: 'invalid key'},
          ],
          'vectors': <String, Object?>{},
          'points': <String, Object?>{},
        }),
        invalidField('sources'),
      );
      final decoded = schema.decode({
        'sources': <Object?>[],
        'vectors': <String, Object?>{},
        'points': <String, Object?>{},
        'additive_future_field': true,
      });
      expect(decoded.value<List<String>>('labels'), isEmpty);
      expect(decoded.value<bool>('enabled'), isFalse);
      expect(decoded.value<Object?>('clusters'), isNull);
    },
  );
}
