import 'dart:io';
import 'package:foresight_core/src/agent_access.dart';
import 'package:test/test.dart';

void main() {
  group('bounded import policy', () {
    late Directory temp, root, profile;
    late ImportPolicy policy;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('foresight-import-');
      root = Directory('${temp.path}/allowed')..createSync();
      profile = Directory('${root.path}/profile')..createSync();
      policy = ImportPolicy(profile.path, () => [root.path]);
    });
    tearDown(() => temp.deleteSync(recursive: true));
    test(
      'allows selected files; denies outside roots, profile and symlink escapes',
      () {
        final good = File('${root.path}/good.txt')..writeAsStringSync('hello');
        expect(policy.validate(good.path), good.path);
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
        expect(await policy.directoryFiles(root.path), ['${root.path}/ok.txt']);
      },
    );
  });
  group('connection scoped visible approvals', () {
    late AgentAccessGate gate;
    late Object desktop, agent, stranger;
    late List<Map<String, Object?>> events;
    setUp(() {
      desktop = Object();
      agent = Object();
      stranger = Object();
      events = [];
      gate = AgentAccessGate(
        'private-token',
        (_, event) => events.add(event),
        timeout: const Duration(milliseconds: 50),
      );
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
          'preferences.set',
          'models.register',
        ]) {
          await expectLater(
            gate.authorize(agent, method, {}, current: () => true),
            throwsStateError,
          );
        }
        expect(() => gate.attach(agent, 'guessed-token'), throwsStateError);
      },
    );
    test('approval is per operation and only desktop can decide', () async {
      gate.attach(desktop, 'private-token');
      final pending = gate.authorize(
        agent,
        'workspace.clear',
        {},
        current: () => true,
      );
      expect(events.single['method'], 'workspace.clear');
      final id = events.single['approval_id'] as String;
      expect(() => gate.decide(stranger, id, true), throwsStateError);
      gate.decide(desktop, id, true);
      await pending;
      expect(events.last['event'], 'approval_closed');
      await expectLater(
        gate.authorize(agent, 'workspace.clear', {}, current: () => true),
        throwsStateError,
      );
    });
    test(
      'desktop capture needs confirmation; disconnect invalidates approval',
      () async {
        gate.attach(desktop, 'private-token');
        final pending = gate.authorize(desktop, 'meetings.start', {
          'id': 1,
        }, current: () => true);
        expect(events.single['method'], 'meetings.start');
        gate.detach(desktop);
        await expectLater(pending, throwsStateError);
        expect(gate.hasHost, false);
      },
    );
    test(
      'denial, cancellation, timeout and connection replacement fail closed',
      () async {
        gate.attach(desktop, 'private-token');
        expect(() => gate.attach(stranger, 'private-token'), throwsStateError);
        final pending = gate.authorize(agent, 'sources.import_file', {
          'path': '/secret',
        }, current: () => false);
        gate.decide(desktop, events.single['approval_id'] as String, true);
        await expectLater(pending, throwsStateError);
        await expectLater(
          gate.authorize(agent, 'meetings.start', {}, current: () => true),
          throwsStateError,
        );
        final denied = gate.authorize(
          agent,
          'workspace.clear',
          {},
          current: () => true,
        );
        gate.decide(desktop, events.last['approval_id'] as String, false);
        await expectLater(denied, throwsStateError);
      },
    );
    test('private URL opt-in still requires visible agent approval', () async {
      gate.attach(desktop, 'private-token');
      final pending = gate.authorize(agent, 'sources.import_url', {
        'url': 'http://127.0.0.1/private',
        'allow_private_network': true,
      }, current: () => true);
      expect(events.single['method'], 'sources.import_url');
      expect((events.single['args'] as Map)['allow_private_network'], isTrue);
      gate.decide(desktop, events.single['approval_id'] as String, false);
      await expectLater(pending, throwsStateError);
    });
    test('network augmented answers require approval', () async {
      await expectLater(
        gate.authorize(agent, 'answer.stream', {
          'web_search': true,
        }, current: () => true),
        throwsStateError,
      );
      await gate.authorize(agent, 'answer.stream', {}, current: () => true);
    });
  });
}
