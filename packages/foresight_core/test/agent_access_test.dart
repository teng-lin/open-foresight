import 'package:foresight_test_support/test_paths.dart';
import 'dart:io';
import 'package:foresight_core/src/agent_access.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

void main() {
  group('bounded import policy', () {
    late Directory temp, root, profile;
    late ImportPolicy policy;
    setUp(() {
      temp = createTestTempDirectorySync('foresight-import-');
      root = Directory('${temp.path}/allowed')..createSync();
      profile = Directory('${root.path}/profile')..createSync();
      policy = ImportPolicy(profile.path, () => [root.path]);
    });
    setUp(() {
      addTearDown(() => temp.deleteSync(recursive: true));
    });
    test(
      'allows selected files; denies outside roots, profile and symlink escapes',
      () {
        final good = File('${root.path}/good.txt')..writeAsStringSync('hello');
        expect(policy.validate(good.path), good.resolveSymbolicLinksSync());
        final secret = File('${profile.path}/tokens.json')
          ..writeAsStringSync('secret');
        final outside = File('${temp.path}/outside.txt')
          ..writeAsStringSync('secret');
        expect(() => policy.validate(secret.path), throwsStateError);
        expect(() => policy.validate(outside.path), throwsStateError);
        expect(
          () => policy.validate('${root.path}/../outside.txt'),
          throwsStateError,
        );
        Link('${root.path}/escape.txt').createSync(secret.path);
        expect(
          () => policy.validate('${root.path}/escape.txt'),
          throwsStateError,
        );
      },
    );
    test(
      'denies devices, pipes, directories and oversized files without opening',
      () {
        expect(() => policy.validate('/dev/zero'), throwsStateError);
        expect(() => policy.validate(root.path), throwsStateError);
        final pipe = '${root.path}/pipe.txt';
        expect(Process.runSync('mkfifo', [pipe]).exitCode, 0);
        expect(() => policy.validate(pipe), throwsStateError);
        final large = File(
          '${root.path}/large.txt',
        ).openSync(mode: FileMode.write);
        large.truncateSync(ImportPolicy.maxFileBytes + 1);
        large.closeSync();
        expect(
          () => policy.validate('${root.path}/large.txt'),
          throwsStateError,
        );
      },
    );
    test(
      'directory scan rejects nested profile and skips symlink traversal',
      () async {
        File('${profile.path}/secret.txt').writeAsStringSync('secret');
        await expectLater(policy.directoryFiles(root.path), throwsStateError);
        profile.deleteSync(recursive: true);
        File('${root.path}/ok.txt').writeAsStringSync('hello');
        Link('${root.path}/escape.txt').createSync('/dev/zero');
        expect(await policy.directoryFiles(root.path), [
          File('${root.path}/ok.txt').resolveSymbolicLinksSync(),
        ]);
      },
    );
  });
  test(
    'identical approval requests are limited per connection and expire',
    () async {
      var now = DateTime.utc(2026);
      final events = <Map<String, Object?>>[];
      final host = Object(), client = Object();
      final gate = AgentAccessGate('token', (_, event) {
        events.add(event);
        return EventDelivery.sent;
      }, now: () => now);
      gate.attach(host, 'token', verifiedDesktop: true);
      for (var i = 0; i < 3; i++) {
        final work = gate.authorize(client, 'sources.import_url', {
          'url': 'https://example.test',
          'allow_private_network': true,
          'requestId': '$i',
        }, current: () => true);
        final approval = events.last;
        expect(approval['requester'], contains('identity unverified'));
        expect(
          approval['risk_flags'],
          contains('Private network access requested'),
        );
        gate.decide(host, approval['approval_id'] as String, true);
        await work;
      }
      await expectLater(
        gate.authorize(client, 'sources.import_url', {
          'url': 'https://example.test',
          'allow_private_network': true,
        }, current: () => true),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.busy,
          ),
        ),
      );
      now = now.add(const Duration(minutes: 1));
      final next = gate.authorize(client, 'sources.import_url', {
        'url': 'https://example.test',
        'allow_private_network': true,
      }, current: () => true);
      gate.decide(host, events.last['approval_id'] as String, true);
      await next;
    },
  );

  test('an approval the desktop never received fails its request with the '
      'reason it was not delivered', () async {
    for (final (delivery, code, message) in [
      (
        EventDelivery.tooLarge,
        RpcErrorCode.invalidArgument,
        'Request is too large to show for approval',
      ),
      (
        EventDelivery.unencodable,
        RpcErrorCode.invalidArgument,
        'Request contains a value JSON cannot represent, such as NaN or '
            'Infinity, so it cannot be shown for approval',
      ),
      (
        EventDelivery.writeFailed,
        RpcErrorCode.unavailable,
        'The desktop approval window could not be reached; retry once the '
            'desktop app is open',
      ),
    ]) {
      final host = Object(), client = Object();
      final gate = AgentAccessGate(
        'token',
        (_, event) =>
            event['event'] == 'approval' ? delivery : EventDelivery.sent,
      );
      gate.attach(host, 'token', verifiedDesktop: true);
      await expectLater(
        gate.authorize(client, 'sources.delete', {
          'id': 'source',
        }, current: () => true),
        throwsA(
          isA<RpcError>()
              .having((error) => error.code, 'code', code)
              .having((error) => error.message, 'message', message),
        ),
      );
    }
  });

  test(
    'approval IDs are random, so a replacement owner never repeats one',
    () async {
      final ids = <Object?>[];
      for (var owner = 0; owner < 2; owner++) {
        final host = Object(), client = Object();
        final gate = AgentAccessGate('token', (_, event) {
          if (event['event'] == 'approval') ids.add(event['approval_id']);
          return EventDelivery.sent;
        });
        gate.attach(host, 'token', verifiedDesktop: true);
        final work = gate.authorize(client, 'sources.delete', {
          'id': 'source',
        }, current: () => true);
        gate.decide(host, ids.last as String, false);
        await expectLater(
          work,
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.denied,
            ),
          ),
        );
      }
      expect(ids, everyElement(matches(RegExp(r'^approval-[0-9a-f]{16}$'))));
      expect(ids.toSet(), hasLength(2));
    },
  );

  group('connection scoped visible approvals', () {
    late AgentAccessGate gate;
    late Object desktop, agent, stranger;
    late List<Map<String, Object?>> events;
    setUp(() {
      desktop = Object();
      agent = Object();
      stranger = Object();
      events = [];
      gate = AgentAccessGate('private-token', (_, event) {
        events.add(event);
        return EventDelivery.sent;
      }, timeout: const Duration(milliseconds: 50));
    });
    test(
      'reads work without desktop; protected operations fail closed',
      () async {
        await gate.authorize(agent, 'sources.get', {}, current: () => true);
        for (final method in [
          'meetings.start',
          'meetings.resume',
          'sources.import_file',
          'sources.import_url',
          'sources.import_directory',
          'sources.delete',
          'workspace.clear',
          'google.sign_in',
          'google.add_account',
          'google.switch_account',
          'google.sign_out_account',
          'preferences.set',
          'models.register',
        ]) {
          await expectLater(
            gate.authorize(agent, method, {}, current: () => true),
            throwsA(
              isA<RpcError>().having(
                (error) => error.code,
                'code',
                RpcErrorCode.denied,
              ),
            ),
          );
        }
        expect(
          () => gate.attach(agent, 'guessed-token', verifiedDesktop: true),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.denied,
            ),
          ),
        );
      },
    );
    test('approval is per operation and only desktop can decide', () async {
      gate.attach(desktop, 'private-token', verifiedDesktop: true);
      final pending = gate.authorize(
        agent,
        'workspace.clear',
        {},
        current: () => true,
      );
      expect(events.single['method'], 'workspace.clear');
      final id = events.single['approval_id'] as String;
      expect(
        () => gate.decide(stranger, id, true),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
      gate.decide(desktop, id, true);
      await pending;
      expect(events.last['event'], 'approval_closed');
      await expectLater(
        gate.authorize(agent, 'workspace.clear', {}, current: () => true),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
    });
    test(
      'direct desktop start and resume use click consent; agent approval remains scoped',
      () async {
        gate.attach(desktop, 'private-token', verifiedDesktop: true);
        for (final method in ['meetings.start', 'meetings.resume']) {
          await gate.authorize(desktop, method, {'id': 1}, current: () => true);
        }
        expect(events, isEmpty);
        final pending = gate.authorize(agent, 'meetings.start', {
          'id': 1,
        }, current: () => true);
        expect(events.single['method'], 'meetings.start');
        gate.detach(desktop);
        await expectLater(
          pending,
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.denied,
            ),
          ),
        );
        expect(gate.hasHost, false);
      },
    );
    test(
      'denial, cancellation, timeout and connection replacement fail closed',
      () async {
        gate.attach(desktop, 'private-token', verifiedDesktop: true);
        expect(
          () => gate.attach(stranger, 'private-token', verifiedDesktop: true),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.denied,
            ),
          ),
        );
        final pending = gate.authorize(agent, 'sources.import_file', {
          'path': '/secret',
        }, current: () => false);
        gate.decide(desktop, events.single['approval_id'] as String, true);
        await expectLater(
          pending,
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.cancelled,
            ),
          ),
        );
        await expectLater(
          gate.authorize(agent, 'meetings.start', {}, current: () => true),
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.denied,
            ),
          ),
        );
        final denied = gate.authorize(
          agent,
          'workspace.clear',
          {},
          current: () => true,
        );
        gate.decide(desktop, events.last['approval_id'] as String, false);
        await expectLater(
          denied,
          throwsA(
            isA<RpcError>().having(
              (error) => error.code,
              'code',
              RpcErrorCode.denied,
            ),
          ),
        );
      },
    );
    test('private URL opt-in still requires visible agent approval', () async {
      gate.attach(desktop, 'private-token', verifiedDesktop: true);
      final pending = gate.authorize(agent, 'sources.import_url', {
        'url': 'http://127.0.0.1/private',
        'allow_private_network': true,
      }, current: () => true);
      expect(events.single['method'], 'sources.import_url');
      expect((events.single['args'] as Map)['allow_private_network'], isTrue);
      gate.decide(desktop, events.single['approval_id'] as String, false);
      await expectLater(
        pending,
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
    });
    test('network augmented answers require approval', () async {
      await expectLater(
        gate.authorize(agent, 'answer.stream', {
          'web_search': true,
        }, current: () => true),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.denied,
          ),
        ),
      );
      await gate.authorize(agent, 'answer.stream', {}, current: () => true);
    });
  });
}
