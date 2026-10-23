import 'dart:io';
import 'package:open_foresight/desktop_environment.dart';

/// Explicit facts for existing fixtures with runner-specific assertions or ABI.
/// Host effects remain the safe DesktopEnvironment defaults. Tests covering an
/// injected platform directly should choose linux()/macOS() themselves.
PlatformCapabilities get testHostPlatformCapabilities => Platform.isMacOS
    ? const PlatformCapabilities.macOS()
    : const PlatformCapabilities.linux();
