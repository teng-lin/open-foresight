import 'dart:io';

import 'package:foresight_core/src/desktop_connection.dart';
import 'package:foresight_core/src/google_auth.dart';
import 'package:foresight_core/src/google_connections.dart';
import 'package:foresight_core/src/native.dart';
import 'package:foresight_core/src/recording.dart';
import 'package:foresight_core/src/remote_domain.dart';
import 'package:test/test.dart';

// These bounds are checked by the compiler even though no worker is created.
Type generationStatusType<T extends GenerationStatus>() => T;
Type recordingStatusType<T extends RecordingStatus>() => T;
Type googleAccountType<T extends GoogleAccount>() => T;
Type connectedSourcesType<T extends ConnectedSources>() => T;
Type desktopConnectionType<T extends DesktopConnection>() => T;

void main() {
  test(
    'owned workers and remote facades implement the same narrow interfaces',
    () {
      expect(generationStatusType<NativeRuntime>(), NativeRuntime);
      expect(generationStatusType<RemoteRuntime>(), RemoteRuntime);
      expect(recordingStatusType<Recording>(), Recording);
      expect(recordingStatusType<RemoteRecording>(), RemoteRecording);
      expect(googleAccountType<GoogleAuth>(), GoogleAuth);
      expect(googleAccountType<RemoteGoogleAuth>(), RemoteGoogleAuth);
      expect(connectedSourcesType<GoogleConnections>(), GoogleConnections);
      expect(
        connectedSourcesType<RemoteGoogleConnections>(),
        RemoteGoogleConnections,
      );
      expect(desktopConnectionType<RemoteDomain>(), RemoteDomain);
    },
  );

  test(
    'remote facades cannot fall back to noSuchMethod or local Domain logic',
    () {
      final source = File('lib/src/remote_domain.dart').readAsStringSync();
      expect(
        RegExp(r'\bnoSuchMethod\s*\(').allMatches(source),
        isEmpty,
        reason: 'Missing facade members must remain compile errors',
      );
      expect(
        RegExp(r'class\s+RemoteDomain\s+extends\s+Domain\b').hasMatch(source),
        isFalse,
        reason: 'Remote operations must stay in the application service',
      );
    },
  );
}
