import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foresight_core/foresight_core.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_test_support/poll.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:test/test.dart';

Matcher code(RpcErrorCode value) =>
    isA<RpcError>().having((e) => e.code, 'code', value);

void main() {
  late Directory root;
  late ApplicationService service;
  late ServiceClient agent, host;
  late Map<String, String> environment;
  final approvals = <Map<String, dynamic>>[];
  StreamSubscription<Map<String, dynamic>>? events;
  setUp(() async {
    environment = Map.of(runtimeConfiguration.environment);
    runtimeConfiguration.environment.removeWhere(
      (key, _) =>
          key.startsWith('FORESIGHT_') && key != 'FORESIGHT_SQLITE_LIBRARY',
    );
    runtimeConfiguration.environment['FORESIGHT_HELPER'] = '';
    root = createTestTempDirectorySync('admit-');
    service = await ApplicationService.start(
      ProfilePaths('${root.path}/d', '${root.path}/r'),
    );
    await service.ready;
    agent = await ServiceClient.connect(service.path);
    host = await ServiceClient.connect(service.path);
    approvals.clear();
    events = host.events.stream.listen((event) {
      if (event['event'] == 'approval') approvals.add(event);
    });
    addTearDown(() async {
      await events?.cancel();
      await agent.close();
      await host.close();
      await service.close();
      await eventually(() => service.dispatchedCount == 0);
      runtimeConfiguration.environment
        ..clear()
        ..addAll(environment);
    });
  });
  String token() =>
      File('${root.path}/d/.desktop-capability').readAsStringSync();
  Future<void> attach() async =>
      host.call(Operation.securityAttachDesktop.wire, {'token': token()});

  test(
    'malformed approval-requiring request sends correlated invalidArgument without approval',
    () async {
      await attach();
      await expectLater(
        agent.call(Operation.sourcesImport.wire, {'title': 42, 'text': 'body'}),
        throwsA(code(RpcErrorCode.invalidArgument)),
      );
      await host.call(Operation.status.wire);
      expect(approvals, isEmpty);
      expect(service.lastAgentActivity, isNull);
      expect(service.dispatchedCount, 0);
      expect(service.domain.store.sources, isEmpty);
      // A rejected frame leaves multiplexed requests usable.
      expect(await agent.call(Operation.notesList.wire), isEmpty);
    },
  );

  test(
    'malformed stale beats epoch refusal while valid stale never asks approval',
    () async {
      await attach();
      for (final malformed in [true, false]) {
        await expectLater(
          agent.call(Operation.sourcesImport.wire, {
            'id': 'missing',
            'title': malformed ? 42 : 'valid',
            'text': 'body',
            'workspace_epoch': 'stale',
          }),
          throwsA(
            code(
              malformed ? RpcErrorCode.invalidArgument : RpcErrorCode.notFound,
            ),
          ),
        );
      }
      await host.call(Operation.status.wire);
      expect(approvals, isEmpty);
      expect(service.lastAgentActivity, isNull);
      expect(service.dispatchedCount, 0);
    },
  );

  test(
    'malformed bootstrap cannot attach or reserve desktop presence',
    () async {
      await expectLater(
        host.call(Operation.securityAttachDesktop.wire, {'token': 42}),
        throwsA(code(RpcErrorCode.invalidArgument)),
      );
      await expectLater(
        host.call(Operation.status.wire, {'desktop': true, 'token': 42}),
        throwsA(code(RpcErrorCode.invalidArgument)),
      );
      final lifetime =
          (await agent.call(Operation.status.wire) as Map)['lifetime'] as Map;
      expect(lifetime['pinned_by_desktop'], isFalse);
      expect(service.access.hasHost, isFalse);
      expect(service.lastAgentActivity, isNull);
    },
  );

  test(
    'incompatible explicit startup version fails before capability reservation',
    () async {
      await expectLater(
        host.call(Operation.status.wire, {
          'desktop': true,
          'token': token(),
          'client_api_version': 2,
        }),
        throwsA(code(RpcErrorCode.unavailable)),
      );
      final lifetime =
          (await agent.call(Operation.status.wire) as Map)['lifetime'] as Map;
      expect(lifetime['pinned_by_desktop'], isFalse);
      expect(service.access.hasHost, isFalse);
      await host.call(Operation.status.wire, {
        'desktop': true,
        'token': token(),
        'client_api_version': 1,
      });
      expect(
        ((await agent.call(Operation.status.wire) as Map)['lifetime']
            as Map)['pinned_by_desktop'],
        isTrue,
      );
      expect(service.lastAgentActivity, isNull);
    },
  );

  test(
    'bootstrap retains no epoch admission and no dispatched activity',
    () async {
      await host.call(Operation.securityAttachDesktop.wire, {
        'token': token(),
        'workspace_epoch': 'historically-ignored',
      });
      expect(service.access.hasHost, isTrue);
      final directory = Directory('${root.path}/import')..createSync();
      await host.call(Operation.securityAllowImportRoot.wire, {
        'path': directory.path,
        'workspace_epoch': 'historically-ignored',
      });
      expect(
        jsonDecode(service.domain.store.preference('importRoots', '[]')),
        contains(directory.resolveSymbolicLinksSync()),
      );
      await expectLater(
        agent.call(Operation.serviceStopIfIdle.wire, {
          'expected_pid': pid + 1,
          'workspace_epoch': 'historically-ignored',
        }),
        throwsA(code(RpcErrorCode.cancelled)),
      );
      expect(service.lastAgentActivity, isNull);
      expect(service.dispatchedCount, 0);
      await host.call(Operation.securityDetachDesktop.wire, {
        'workspace_epoch': 'historically-ignored',
      });
      expect(service.access.hasHost, isFalse);
    },
  );

  test('malformed idle-stop ownership fields do not close service', () async {
    await expectLater(
      agent.call(Operation.serviceStopIfIdle.wire, {'expected_pid': 'bad'}),
      throwsA(code(RpcErrorCode.invalidArgument)),
    );
    expect((await agent.call(Operation.status.wire) as Map)['pid'], pid);
    expect(service.lastAgentActivity, isNull);
    expect(service.dispatchedCount, 0);
  });
}
