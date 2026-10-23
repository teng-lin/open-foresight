import 'dart:io';

// Explicit injection for service fixtures whose synthetic desktop lives in
// this test process. Production never trusts a generic test/Dart executable.
// ignore: implementation_imports
import 'package:foresight_core/src/unix_peer_identity.dart';

bool trustInProcessDesktop(Socket socket) {
  final identity = unixPeerIdentity(socket);
  return identity.pid == pid && identity.uid == effectiveUserId;
}
