import 'package:foresight_test_support/desktop_identity.dart';
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
      desktopPeerVerifier: trustInProcessDesktop,
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
  Future<void> attach() async => host.call(
    Operation.securityAttachDesktop.wire,
    {'visible': true, 'token': token()},
  );

  test(
    'idle shutdown requires a current owner token and refuses a pinned desktop',
    () async {
      for (final args in [
        <String, dynamic>{},
        {'token': 'wrong'},
      ]) {
        await expectLater(
          agent.call('service.stop_if_idle', args),
          throwsA(code(RpcErrorCode.denied)),
        );
        expect((await agent.call('status') as Map)['pid'], pid);
      }
      await attach();
      await expectLater(
        agent.call('service.stop_if_idle', {'token': token()}),
        throwsA(code(RpcErrorCode.busy)),
      );
      expect((await agent.call('status') as Map)['pid'], pid);
      expect(approvals, isEmpty);
      await host.close();
      await eventually(() => !service.access.hasHost);
      expect(await agent.call('service.stop_if_idle', {'token': token()}), {
        'stopped': true,
        'shutdown_verified': true,
      });
    },
  );

  test(
    'agent note creation needs no replacement consent; overwrites do',
    () async {
      final created =
          await agent.call('notes.save', {
                'title': 'original',
                'body': 'trusted',
              })
              as Map;
      final id = created['id'];
      await attach();
      final work = agent.call('notes.save', {
        'id': id,
        'title': 'agent',
        'body': 'replacement',
      });
      await eventually(() => approvals.isNotEmpty);
      expect(service.domain.store.notes().single['body'], 'trusted');
      await host.call('security.decide', {
        'approval_id': approvals.single['approval_id'],
        'allow': true,
      });
      await work;
      expect(service.domain.store.notes().single['body'], 'replacement');
      expect(
        service.domain.store.contentHistory
            .revisions('notes', id as int)
            .single['snapshot'],
        containsPair('body', 'trusted'),
      );
    },
  );

  test(
    'a replacement approval cannot authorize bytes changed by the desktop',
    () async {
      final id = service.domain.store.saveNote(null, 'original', 'trusted');
      await attach();
      final work = agent.call('notes.save', {
        'id': id,
        'title': 'agent',
        'body': 'replacement',
      });
      final refused = expectLater(work, throwsA(code(RpcErrorCode.cancelled)));
      await eventually(() => approvals.isNotEmpty);
      await host.call('notes.save', {
        'id': id,
        'title': 'desktop',
        'body': 'new trusted',
      });
      await host.call('security.decide', {
        'approval_id': approvals.single['approval_id'],
        'allow': true,
      });
      await refused;
      expect(service.domain.store.notes().single['body'], 'new trusted');
    },
  );

  for (final method in [
    'meetings.notes',
    'artifacts.edit',
    'meetings.edit_task',
    'meetings.prepare',
    'meetings.enhance',
    'meetings.generate',
  ]) {
    test('$method cannot replace trusted content without approval', () async {
      final store = service.domain.store;
      final meeting = store.meeting('protected');
      store.saveMeetingNotes(meeting, 'trusted raw notes');
      store.saveMeetingEnhancedDraft(meeting, 'trusted enhanced notes');
      for (final kind in [
        'summary',
        'actions',
        'preparation',
        'enhanced_notes',
      ]) {
        store.artifact(meeting, kind, 'trusted $kind', 'fixture');
      }
      final artifact = store
          .rows("SELECT id FROM artifacts WHERE kind='summary'")
          .single['id'];
      store.db.execute(
        "INSERT INTO meeting_tasks(meeting_id,task_key,task,status,evidence,input_revision) VALUES(?,'task','trusted task','open','[]',0)",
        [meeting],
      );
      final task = store.db.lastInsertRowId;
      final args = switch (method) {
        'artifacts.edit' => {'id': artifact, 'text': 'replacement'},
        'meetings.edit_task' => {'id': task, 'task': 'replacement'},
        'meetings.notes' => {'id': meeting, 'body': 'replacement'},
        'meetings.prepare' => {
          'id': meeting,
          'source_ids': ['source'],
        },
        'meetings.generate' => {'id': meeting, 'kind': 'summary'},
        _ => {'id': meeting},
      };
      final before = store.rows('SELECT * FROM content_revisions');
      await attach();
      final work = agent.call(method, args);
      final refused = expectLater(work, throwsA(code(RpcErrorCode.denied)));
      await eventually(() => approvals.isNotEmpty);
      await host.call('security.decide', {
        'approval_id': approvals.single['approval_id'],
        'allow': false,
      });
      await refused;
      expect(store.rows('SELECT * FROM content_revisions'), before);
      expect(service.dispatchedCount, 0);
    });
  }

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
        host.call(Operation.securityAttachDesktop.wire, {
          'visible': true,
          'token': 42,
        }),
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
        'visible': true,
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
        throwsA(code(RpcErrorCode.denied)),
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
