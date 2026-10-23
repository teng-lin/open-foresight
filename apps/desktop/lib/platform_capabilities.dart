/// Platform policy supplied with the desktop's host-effect adapter.
///
/// Tests select these facts explicitly; constructing a widget never inspects
/// the machine running it. The supported production targets remain macOS and
/// Linux.
final class PlatformCapabilities {
  const PlatformCapabilities.linux() : _macOS = false;
  const PlatformCapabilities.macOS() : _macOS = true;

  final bool _macOS;

  bool get usesAccountHomeLookup => _macOS;
  bool get usesNativeMenu => _macOS;
  bool get usesNativeCalendarLinks => _macOS;
  bool get usesNativeLoginItems => _macOS;
  bool get usesNativeShortcuts => _macOS;
  bool get usesMetaShortcuts => _macOS;
  bool get requiresAudioPermissions => _macOS;
  bool get requiresNotificationPermission => _macOS;
  bool get supportsSystemAudioSettings => _macOS;
  bool get supportsEchoCancellation => _macOS;
  bool get supportsWebContentAcquisition => _macOS;
  bool get supportsHyprland => !_macOS;
  String get deviceName => _macOS ? 'Mac' : 'computer';
}
