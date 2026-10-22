import 'package:foresight_core/desktop.dart';

/// Captures action ownership independently of ordinary data revisions.
/// A retained reader does not preserve a replaced client or workspace session.
final class FeatureRequestIdentity {
  FeatureRequestIdentity.capture(DesktopConnection connection)
    : _connection = connection,
      _session = connection.clientSessionGeneration,
      _clientEpoch = connection.workspaceEpoch,
      _storedEpoch = connection.store.workspaceEpoch;

  final DesktopConnection _connection;
  final Object _session;
  final String? _clientEpoch;
  final String _storedEpoch;

  String get workspaceEpoch => _clientEpoch ?? _storedEpoch;

  bool isCurrent(DesktopConnection connection, {required bool alive}) {
    if (!alive ||
        !identical(connection, _connection) ||
        !identical(connection.clientSessionGeneration, _session) ||
        connection.workspaceEpoch != _clientEpoch ||
        (_storedEpoch.isNotEmpty && workspaceEpoch != _storedEpoch)) {
      return false;
    }
    try {
      return connection.store.workspaceEpoch == _storedEpoch;
    } catch (_) {
      return false;
    }
  }
}
