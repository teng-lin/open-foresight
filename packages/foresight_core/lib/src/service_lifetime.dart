import 'dart:io';
import 'operations.dart';

class ServiceRequestLease {
  final String id;
  final Operation operation;
  String get method => operation.wire;
  final bool agent;
  bool streamed = false;
  bool helperWait = false;
  bool cancelled = false;
  // Set only while the request waits for desktop approval or helper
  // readiness, and cleared just before dispatch. A close refuses a waiting
  // request like a new one; any other is outcomeUnknown.
  bool waiting = false;
  ServiceRequestLease(this.id, this.operation, {required this.agent});
}

/// One ledger tracks admitted leases separately from dispatched producers.
/// Removing a socket lease never settles the producer behind it.
class ServiceRequestLedger {
  final leases = <Socket, Map<int, ServiceRequestLease>>{};
  final _dispatched = <ServiceRequestLease>{};
  int get dispatchedCount => _dispatched.length;
  bool get operationsBusy =>
      leases.values.any(
        (items) =>
            items.values.any((lease) => lease.operation.descriptor.leaseBusy),
      ) ||
      _dispatched.isNotEmpty;
  bool get agentWorkInFlight =>
      leases.values.any(
        (items) => items.values.any(
          (lease) =>
              lease.agent &&
              lease.helperWait &&
              lease.operation.descriptor.leaseBusy,
        ),
      ) ||
      _dispatched.any((lease) => lease.agent);
  bool dispatch(ServiceRequestLease lease) {
    lease.waiting = false;
    lease.helperWait = false;
    if (!lease.operation.descriptor.leaseBusy) return false;
    _dispatched.add(lease);
    return true;
  }

  bool settle(ServiceRequestLease lease) => _dispatched.remove(lease);
}

/// An ephemeral decision snapshot: no clock, timer, activity writes or shutdown
/// side effects. ApplicationService remains their sole authority.
class ServiceLifetimeSnapshot {
  const ServiceLifetimeSnapshot({
    required this.started,
    required this.lastAgentActivity,
    required this.lastDesktopDeparture,
    required this.idleMinutes,
    required this.desktopDetachGrace,
    required this.pinned,
    required this.busy,
    required this.agentWorkInFlight,
    required this.mutating,
    required this.closing,
  });
  final DateTime started;
  final DateTime? lastAgentActivity, lastDesktopDeparture;
  final double idleMinutes;
  final Duration desktopDetachGrace;
  final bool pinned, busy, agentWorkInFlight, closing;
  final int mutating;
  Duration? get period => idleMinutes == 0
      ? null
      : Duration(milliseconds: (idleMinutes * 60000).round());
  DateTime? get exitAfter {
    if (closing || pinned) return null;
    if (lastDesktopDeparture != null) {
      return lastDesktopDeparture!.add(desktopDetachGrace);
    }
    final timeout = period;
    if (timeout == null || busy) return null;
    return (lastAgentActivity ?? started).add(timeout);
  }

  bool shouldArmDesktopDeparture(DateTime now) {
    if (pinned || closing || agentWorkInFlight) return false;
    final last = lastAgentActivity;
    final timeout = period;
    return last == null ||
        (timeout != null &&
            !now.difference(last).isNegative &&
            now.difference(last) >= timeout);
  }

  bool shouldExit(DateTime now) {
    if (closing || pinned) return false;
    if (lastDesktopDeparture != null) {
      return !now.isBefore(lastDesktopDeparture!.add(desktopDetachGrace)) &&
          !agentWorkInFlight &&
          mutating == 0;
    }
    final timeout = period;
    return timeout != null &&
        !busy &&
        !now.isBefore((lastAgentActivity ?? started).add(timeout));
  }

  Map<String, Object?> toJson() => {
    'pinned_by_desktop': pinned,
    'busy': busy,
    'last_agent_activity': lastAgentActivity?.millisecondsSinceEpoch,
    'idle_minutes': idleMinutes,
    'exit_after': exitAfter?.millisecondsSinceEpoch,
  };
}
