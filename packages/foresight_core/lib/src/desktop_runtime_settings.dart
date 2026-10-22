import 'platform_services.dart';

/// Read-only presentation/configuration values. Profile paths, credentials and
/// the mutable process environment never cross the desktop feature boundary.
final class DesktopRuntimeSettings {
  final String nativeLibrary;
  final Map<String, String> _resources;
  final bool webContentAvailable;
  DesktopRuntimeSettings._()
    : nativeLibrary = runtimeConfiguration.nativeLibrary,
      webContentAvailable =
          (runtimeConfiguration['FORESIGHT_WEB_CONTENT_API_KEY'] ?? '')
              .isNotEmpty,
      _resources = Map.unmodifiable({
        for (final key in [
          'FORESIGHT_LITERT_RUNNER',
          'FORESIGHT_WHISPER_RUNTIME',
          'FORESIGHT_NOTIFICATIONS',
        ])
          if (runtimeConfiguration[key] case final String value) key: value,
      });

  String? operator [](String key) => _resources[key];
}

DesktopRuntimeSettings get desktopRuntimeSettings => DesktopRuntimeSettings._();
