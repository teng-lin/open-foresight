import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pump_until.dart';

final _ownerKey = Object();

typedef _Owner = ({void Function() close, Future<void> Function() settled});

final class _FixtureOwners {
  final owners = <_Owner>[];
  final failures = <(Object, StackTrace)>[];
  var closing = false, pending = 0;

  void add(_Owner owner) {
    owners.add(owner);
    if (closing) _begin(owner);
  }

  void _begin(_Owner owner) {
    pending++;
    try {
      owner.close();
    } catch (error, stack) {
      failures.add((error, stack));
    }
    unawaited(
      Future<void>.sync(owner.settled).then<void>(
        (_) => pending--,
        onError: (Object error, StackTrace stack) {
          failures.add((error, stack));
          pending--;
        },
      ),
    );
  }

  void close() {
    closing = true;
    for (final owner in owners.toList()) {
      _begin(owner);
    }
  }
}

/// Registers only with the current callback's owner scope. No global registry,
/// timer override, alternate binding or production resource hook is involved.
void registerDesktopFixtureOwner({
  required void Function() close,
  required Future<void> Function() settled,
}) {
  (Zone.current[_ownerKey] as _FixtureOwners?)?.add((
    close: close,
    settled: settled,
  ));
}

/// Keep Flutter's normal invariants after disposing the tree and joining its
/// real application/Domain/helper/Store owners inside the widget callback.
Future<void> withDesktopFixtures(
  WidgetTester tester,
  Future<void> Function() body, {
  Duration closeTimeout = const Duration(seconds: 5),
}) async {
  final owners = _FixtureOwners();
  Object? primary;
  StackTrace? primaryStack;
  await runZoned(() async {
    try {
      await body();
    } catch (error, stack) {
      primary = error;
      primaryStack = stack;
    }
    try {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        owners.close();
        await pumpUntil(
          tester,
          () => owners.pending == 0,
          timeout: closeTimeout,
        );
        if (owners.failures.isNotEmpty) {
          final (error, stack) = owners.failures.first;
          Error.throwWithStackTrace(error, stack);
        }
      }
    } catch (error, stack) {
      if (primary == null) {
        primary = error;
        primaryStack = stack;
      } else {
        // Keep both failures visible while rethrowing the original assertion.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            context: ErrorDescription('joining desktop fixture owners'),
          ),
        );
      }
    } finally {
      owners.owners.clear();
    }
  }, zoneValues: {_ownerKey: owners});
  if (primary != null) Error.throwWithStackTrace(primary!, primaryStack!);
}
