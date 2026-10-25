import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/application_services/audio_operations.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:test/test.dart';

void main() {
  test(
    'service enumeration preserves typed device data without requesting access',
    () async {
      var enumerations = 0, permissions = 0;
      final audio = AudioOperations(
        enumerate: () async {
          enumerations++;
          return [const AudioDevice('mic', 'Microphone café', false)];
        },
        capabilities: () => {'permission': 'not_requested'},
        requestSystem: () async {
          permissions++;
          return {};
        },
        requestMicrophone: () async {
          permissions++;
          return {};
        },
      );
      final handler = audio.handlers.singleWhere(
        (handler) => handler.operation == Operation.audioCapabilities,
      );
      final ordinary = await handler.invoke(
        decodeOperationRequest(Operation.audioCapabilities, {}),
      );
      expect(ordinary, {'permission': 'not_requested'});
      expect(enumerations, 0);
      final response =
          await handler.invoke(
                decodeOperationRequest(Operation.audioCapabilities, {
                  'enumerate_devices': true,
                }),
              )
              as Map;
      final device = AudioDevice.fromWire(
        Map<String, Object?>.from((response['devices'] as List).single as Map),
      );
      expect(
        (device.name, device.label, device.playback),
        ('mic', 'Microphone café', false),
      );
      expect(enumerations, 1);
      expect(permissions, 0);
      for (final operation in [
        Operation.audioRequestSystem,
        Operation.audioRequestMicrophone,
      ]) {
        await audio.handlers
            .singleWhere((handler) => handler.operation == operation)
            .invoke(decodeOperationRequest(operation, {}));
      }
      expect(permissions, 2);
      expect(enumerations, 1);
    },
  );

  test(
    'enumeration failure propagates without changing permission state',
    () async {
      final audio = AudioOperations(
        enumerate: () async => throw StateError('device adapter unavailable'),
        capabilities: () => {},
        requestSystem: () async => fail('unexpected permission request'),
        requestMicrophone: () async => fail('unexpected permission request'),
      );
      await expectLater(
        audio.handlers.first.invoke(
          decodeOperationRequest(Operation.audioCapabilities, {
            'enumerate_devices': true,
          }),
        ),
        throwsStateError,
      );
    },
  );
}
