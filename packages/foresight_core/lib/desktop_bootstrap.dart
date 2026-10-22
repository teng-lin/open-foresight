/// Startup-only capabilities, imported by the desktop application bootstrap.
/// Feature modules use desktop.dart and never receive a profile/database path.
library;

import 'src/desktop_connection.dart';
import 'src/profile_paths.dart';
import 'src/remote_domain.dart';

export 'src/profile_paths.dart' show ProfilePaths;
export 'src/platform_services.dart'
    show privateDirectory, privateRuntime, configureProfileRuntime;

Future<DesktopConnection> connectDesktop(ProfilePaths profile) =>
    RemoteDomain.connect(profile);
