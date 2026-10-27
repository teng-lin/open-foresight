import 'sql_support_test_bootstrap.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:foresight_core/foresight_core.dart' show Store, Domain, Helper;
import 'package:foresight_core/src/application.dart';
import 'package:foresight_test_support/test_recording.dart';
import 'dart:io';
import 'dart:isolate';
import 'package:foresight_test_support/capture_process.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:foresight_core/desktop.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/request_fingerprint.dart' as fingerprint;
import 'package:test/test.dart';

final class _Port implements CurrentClientCommandPort {
  final calls = <(Operation, Map<String, dynamic>)>[];
  Object? reply = {'id': 7};
  Object? failure;
  bool Function()? observedCurrent;
  @override
  Future<Object?> command(
    Operation operation, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add((operation, Map.of(args)));
    if (failure case final error?) throw error;
    return reply;
  }

  @override
  Future<Object?> commandCurrent(
    Operation operation,
    Map<String, dynamic> args,
    bool Function() current,
  ) {
    observedCurrent = current;
    return command(operation, args);
  }
}

String _scope(AstNode node) {
  final names = <String>[];
  for (AstNode? parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is ClassDeclaration) names.add(parent.namePart.typeName.lexeme);
    if (parent is MethodDeclaration) names.add(parent.name.lexeme);
    if (parent is FunctionDeclaration) names.add(parent.name.lexeme);
  }
  return names.reversed.join('.');
}

bool _locallyBound(SimpleIdentifier node) {
  bool parameter(FormalParameterList? parameters) =>
      parameters?.parameters.any((p) => p.name?.lexeme == node.name) ?? false;
  for (AstNode? parent = node.parent; parent != null; parent = parent.parent) {
    if (parent is MethodDeclaration && parameter(parent.parameters)) {
      return true;
    }
    if (parent is FunctionExpression && parameter(parent.parameters)) {
      return true;
    }
    if (parent is Block) {
      for (final statement in parent.statements) {
        if (statement.offset >= node.offset) break;
        if (statement is VariableDeclarationStatement &&
            statement.variables.variables.any(
              (v) => v.name.lexeme == node.name,
            )) {
          return true;
        }
      }
    }
  }
  return false;
}

final class _RawReferences extends RecursiveAstVisitor<void> {
  _RawReferences(this.names);
  final Set<String> names;
  final references = <String>[];
  void record(SimpleIdentifier name, String target, String argument) {
    for (
      AstNode? parent = name.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is Comment || parent is CommentReference) return;
    }
    if (names.contains(name.name)) {
      references.add('${_scope(name)}|$target|${name.name}|$argument');
    }
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    record(
      node.methodName,
      node.target?.toSource() ?? '',
      node.argumentList.arguments.firstOrNull?.toSource() ?? '',
    );
    super.visitMethodInvocation(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    record(node.identifier, node.prefix.toSource(), '<tear-off>');
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    record(node.propertyName, node.target?.toSource() ?? '', '<tear-off>');
    super.visitPropertyAccess(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final parent = node.parent;
    if (!node.inDeclarationContext() &&
        parent is! Label &&
        !_locallyBound(node) &&
        !(parent is MethodInvocation && identical(parent.methodName, node)) &&
        !(parent is PrefixedIdentifier && identical(parent.identifier, node)) &&
        !(parent is PropertyAccess && identical(parent.propertyName, node))) {
      record(node, '', '<tear-off>');
    }
    super.visitSimpleIdentifier(node);
  }
}

Map<String, int> _referenceCounts(Iterable<String> references) {
  final counts = <String, int>{};
  for (final reference in references) {
    counts.update(reference, (count) => count + 1, ifAbsent: () => 1);
  }
  return counts;
}

// Closed transport leaves, including their operation/argument and exact count.
// Callback .call sites are explicitly distinguished from ServiceClient leaves;
// adding an operation, alias/tear-off or duplicate call requires owner review.
const _remoteTransportLeaves = <String, int>{
  // StreamController getters carry already received values, not new RPCs.
  'RemoteDomain.changes|_changes|stream|<tear-off>': 1,
  'RemoteDomain.captureLevels|_captureLevels|stream|<tear-off>': 1,
  'RemoteDomain._listen|connection.events|stream|<tear-off>': 1,
  'RemoteDomain._streamCurrent|controller|stream|<tear-off>': 1,
  'RemoteDomain._performDesktopAttach|connection|call|Operation.securityAttachDesktop.wire':
      1,
  'RemoteDomain._syncDesktopVisibility|connection|call|Operation.securityDesktopVisibility.wire':
      1,
  'RemoteDomain.disableDesktopApprovals|client|call|Operation.securityDetachDesktop.wire':
      1,
  'RemoteDomain._apply|_approvalEvents|call|event': 1,
  'RemoteDomain._call|current|stream|method': 1,
  'RemoteDomain.connect|createdForTesting|call|domain': 1,
  'RemoteDomain.command||_call|Operation.securityAllowImportRoot.wire': 1,
  'RemoteDomain.command||_call|operation.wire': 1,
  'RemoteDomain.command|client|call|Operation.status.wire': 1,
  'RemoteDomain._settleLostClear||_call|Operation.status.wire': 1,
  'RemoteDomain._streamCurrent.send|connection|stream|operation.wire': 1,
  'RemoteDomain._streamCurrent.send|current|call|': 2,
  'RemoteDomain._streamCurrent|current|call|': 1,
  'RemoteDomain.commandCurrent||_streamCurrent|operation': 1,
  'RemoteDomain.googleSignIn|client|stream|operation.wire': 1,
  'RemoteDomain.askInConversation||_streamCurrent|Operation.answerStream': 1,
  'RemoteDomain.askWithWebInConversation||_streamCurrent|Operation.answerStream':
      1,
  'RemoteRuntime.cancel|onCancel|call|requestId': 1,
};

void main() {
  bootstrapSqlSupportFixture();
  test('typed descriptors retain one original operation registry', () {
    expect(
      Operation.values.map((operation) => operation.descriptor).toSet(),
      hasLength(Operation.values.length),
    );
    for (final operation in Operation.values) {
      expect(operation.descriptor.requestEncoder, isNotNull);
      expect(operation.descriptor.resultDecoder, isNotNull);
    }
  });
  test('presence, raw envelope and fingerprint survive typed construction', () {
    const raw = <String, dynamic>{
      'title': 'Draft',
      'text': 'Body',
      'id': null,
      'index': false,
      'requestId': 'request-1',
      'workspace_epoch': 'old-workspace',
    };
    const input = SourcesImportInput(
      title: 'Draft',
      text: 'Body',
      id: WireField(null),
      index: WireField(false),
      envelope: ClientEnvelope(
        requestId: WireField('request-1'),
        workspaceEpoch: WireField('old-workspace'),
      ),
    );
    final encoded = sourcesImportDescriptor.requestEncoder.encode(input);
    expect(encoded, raw);
    expect(
      fingerprint.requestArgumentsDigest(encoded),
      fingerprint.requestArgumentsDigest(raw),
    );
    final request = decodeOperationRequest(Operation.sourcesImport, encoded);
    expect(request.rawArguments, raw);
    expect(
      request.context.rawArgumentsDigest,
      fingerprint.requestArgumentsDigest(raw),
    );
    expect(const SourcesImportInput(title: 'Draft', text: 'Body').toWire(), {
      'title': 'Draft',
      'text': 'Body',
    });
    expect(encoded.containsKey('mime'), isFalse);
  });
  test(
    'typed call forwards existing current and captured epoch unchanged',
    () async {
      final port = _Port()..reply = null;
      bool current() => true;
      await meetingsRenameDescriptor.sendCurrent(
        port,
        const MeetingsRenameInput(
          id: 4,
          title: 'Renamed',
          envelope: ClientEnvelope(workspaceEpoch: WireField('captured')),
        ),
        current,
      );
      expect(identical(port.observedCurrent, current), isTrue);
      expect(port.calls.single.$1, Operation.meetingsRename);
      expect(port.calls.single.$2, {
        'id': 4,
        'title': 'Renamed',
        'workspace_epoch': 'captured',
      });
    },
  );
  test(
    'schema rejection occurs before transport without filling defaults',
    () async {
      final port = _Port();
      await expectLater(
        meetingsRenameDescriptor.send(
          port,
          const MeetingsRenameInput(id: 4, title: ''),
        ),
        throwsA(
          isA<RpcError>().having(
            (error) => error.code,
            'code',
            RpcErrorCode.invalidArgument,
          ),
        ),
      );
      expect(port.calls, isEmpty);
    },
  );
  test(
    'malformed committed reply keeps the same pending key for retry',
    () async {
      final port = _Port()..reply = {'id': 'wrong-type-private-canary'};
      final pending = PendingRequestKey();
      await expectLater(
        meetingsCreateDescriptor.sendKeyed(
          pending,
          port,
          const MeetingsCreateInput(title: 'Draft'),
          sendEnvelope: const ClientEnvelope(
            workspaceEpoch: WireField('captured'),
          ),
        ),
        throwsA(
          isA<RpcError>()
              .having((error) => error.code, 'code', RpcErrorCode.internal)
              .having(
                (error) => error.reason,
                'reason',
                RpcErrorReason.outcomeUnknown,
              )
              .having(
                (error) => error.message.contains('private-canary'),
                'canary absent',
                false,
              ),
        ),
      );
      final key = pending.pending;
      expect(key, isNotNull);
      port.reply = {'id': 41};
      final IntegerIdentityResult result = await meetingsCreateDescriptor
          .sendKeyed(
            pending,
            port,
            const MeetingsCreateInput(title: 'Draft'),
            sendEnvelope: const ClientEnvelope(
              workspaceEpoch: WireField('captured'),
            ),
          );
      expect(result.id, 41);
      expect(port.calls.map((call) => call.$2['idempotency_key']), [key, key]);
      expect(
        port.calls.every((call) => call.$2['workspace_epoch'] == 'captured'),
        isTrue,
      );
      expect(pending.pending, isNull);
    },
  );
  test(
    'edited uncertain retry learns first result before typed amendment',
    () async {
      final port = _Port()
        ..failure = RpcError(
          RpcErrorCode.unavailable,
          'lost',
          reason: RpcErrorReason.outcomeUnknown,
        );
      final pending = PendingRequestKey();
      await expectLater(
        notesSaveDescriptor.sendKeyed(
          pending,
          port,
          const NotesSaveInput(title: 'Original', body: 'First'),
        ),
        throwsA(isA<RpcError>()),
      );
      final key = pending.pending;
      port.failure = null;
      final result = await notesSaveDescriptor.sendKeyed(
        pending,
        port,
        const NotesSaveInput(title: 'Edited', body: 'Second'),
        amend: (first, edited) async {
          expect(port.calls.last.$2, {
            'title': 'Original',
            'body': 'First',
            'idempotency_key': key,
          });
          return notesSaveDescriptor.send(
            port,
            NotesSaveInput(
              id: WireField(first.id),
              title: edited.title,
              body: edited.body,
            ),
          );
        },
      );
      expect(result.id, 7);
      expect(port.calls.last.$2, {
        'id': 7,
        'title': 'Edited',
        'body': 'Second',
      });
      expect(pending.pending, isNull);
    },
  );
  test(
    'transport refusal identity and code are preserved without local retry',
    () async {
      final failure = RpcError(
        RpcErrorCode.unavailable,
        'closing',
        reason: RpcErrorReason.notSent,
      );
      final port = _Port()..failure = failure;
      await expectLater(
        meetingsCreateDescriptor.send(
          port,
          const MeetingsCreateInput(title: 'Draft'),
        ),
        throwsA(same(failure)),
      );
      expect(port.calls, hasLength(1));
    },
  );
  test(
    'partial audio capability fields retain presence during typed decoding',
    () {
      final result = audioRequestSystemDescriptor.decodeResponse({
        'system_audio_request': 'requesting',
        'permission_verified': false,
      });
      expect(result.systemAudioRequest.value, 'requesting');
      expect(result.microphone.present, false);
      expect(result.toWire(), {
        'system_audio_request': 'requesting',
        'permission_verified': false,
      });
    },
  );
  test('void keyed acknowledgement settles the existing retry owner', () async {
    final port = _Port()..reply = null;
    final pending = PendingRequestKey();
    await meetingsTranscriptDescriptor.sendKeyed(
      pending,
      port,
      const MeetingsTranscriptInput(id: 4, text: 'Imported'),
    );
    expect(port.calls.single.$1, Operation.meetingsTranscript);
    expect(pending.pending, isNull);
  });
  test('collection inputs own immutable snapshots before transport', () {
    final labels = ['one'];
    final input = LabelsSetInput(id: 'source', labels: labels);
    labels.add('later');
    expect(input.labels, ['one']);
    expect(() => input.labels.add('forbidden'), throwsUnsupportedError);
    final vectors = <String, List<double>>{
      'source': [1, 2],
    };
    final graph = GraphSaveInput(
      identity: 'layout',
      sources: [],
      vectors: vectors,
      points: {},
    );
    vectors['source']![0] = 99;
    vectors.clear();
    expect(graph.vectors, {
      'source': [1, 2],
    });
    expect(() => graph.vectors['source']!.add(3), throwsUnsupportedError);
  });
  test(
    'compiler rejects a different operation request and wrong result use',
    () async {
      final root = createTestTempDirectorySync('typed-client-');
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:foresight_core/desktop.dart'),
      );
      final packages =
          '${File(library!.toFilePath()).parent.parent.path}/.dart_tool/package_config.json';
      Future<ProcessResult> compile(String name, String source) async {
        final file = File('${root.path}/$name.dart')..writeAsStringSync(source);
        return runCaptureProcess(Platform.resolvedExecutable, [
          'compile',
          'kernel',
          '--packages=$packages',
          file.path,
          '-o',
          '${root.path}/$name.dill',
        ], timeout: const Duration(seconds: 30));
      }

      const prefix = "import 'package:foresight_core/desktop.dart';\n";
      final valid = await compile(
        'valid',
        "${prefix}Future<IntegerIdentityResult> call(ClientCommandPort owner) => meetingsCreateDescriptor.send(owner, const MeetingsCreateInput(title: 'Draft'));\nvoid main() {}\n",
      );
      expect(valid.exitCode, 0, reason: '${valid.stdout}\n${valid.stderr}');
      final invalid = await compile(
        'invalid_request',
        "${prefix}Future<void> call(ClientCommandPort owner) => meetingsRenameDescriptor.send(owner, const SourcesDeleteInput(id: 'source'));\nvoid main() {}\n",
      );
      final diagnostics = '${invalid.stdout}\n${invalid.stderr}';
      expect(invalid.exitCode, isNot(0), reason: diagnostics);
      expect(diagnostics, contains("can't be assigned"));
      expect(diagnostics, contains('SourcesDeleteInput'));
      expect(diagnostics, contains('MeetingsRenameInput'));
      final wrongResult = await compile(
        'invalid_result',
        "${prefix}Future<String> call(ClientCommandPort owner) => meetingsCreateDescriptor.send(owner, const MeetingsCreateInput(title: 'Draft'));\nvoid main() {}\n",
      );
      final resultDiagnostics = '${wrongResult.stdout}\n${wrongResult.stderr}';
      expect(wrongResult.exitCode, isNot(0), reason: resultDiagnostics);
      expect(resultDiagnostics, contains('IntegerIdentityResult'));
      expect(resultDiagnostics, contains('Future<String>'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test('partial Drive metadata retains absent optional fields', () {
    final result = googleDriveFilesDescriptor.decodeResponse([
      {'id': 'doc'},
    ]);
    expect(result.single.id, 'doc');
    expect(result.single.name.present, false);
    expect(result.single.mimeType.present, false);
    expect(result.single.toWire(), {'id': 'doc'});
  });
  test(
    'actual application capture and cancellation replies match their contracts',
    () async {
      final root = createTestTempDirectorySync('client-results-');
      final store = Store('${root.path}/profile.db');
      final helper = Helper(
        '${root.path}/unused.sock',
        '${root.path}/helper',
        manageProcess: false,
      );
      final domain = Domain(store, helper);
      final app = Application(domain);
      addTearDown(() async {
        await app.close();
        domain.close();
        await domain.drain();
        await helper.close();
        store.close();
      });
      final meeting = store.meeting('Controlled capture');
      final cancelled = await app.call('meetings.cancel_enhance', {
        'id': meeting,
      });
      expect(
        meetingsCancelEnhanceDescriptor.decodeResponse(cancelled),
        isFalse,
      );
      app.recording = TestRecording();
      app.recordingMeeting = meeting;
      final stopped = await app.call('meetings.stop', {});
      final snapshot = meetingsStopDescriptor.decodeResponse(stopped);
      expect(snapshot.active, false);
      expect(app.recording, isNull);
      expect(store.rows('SELECT * FROM meeting_index_jobs'), isEmpty);
    },
  );
  test('void replies retain v1 opaque acknowledgement compatibility', () async {
    final port = _Port()..reply = {'cleared': true};
    await workspaceClearDescriptor.send(port, const WorkspaceClearInput());
    expect(port.calls.single.$1, Operation.workspaceClear);
    expect(googleRefreshDescriptor.decodeResponse(null), isNull);
    expect(
      googleRefreshDescriptor.decodeResponse({'connected': true})!.connected,
      true,
    );
  });
  test('desktop and client proxies retain zero raw command callsites', () async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:foresight_core/desktop.dart'),
    );
    final core = File(library!.toFilePath()).parent.parent;
    final repo = core.parent.parent;
    final files = [
      ...Directory('${repo.path}/apps/desktop/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart')),
      for (final name in [
        'remote_domain',
        'remote_google',
        'desktop_audio',
        'desktop_model_downloads',
      ])
        File('${core.path}/lib/src/$name.dart'),
    ];
    final violations = <String>[];
    for (final file in files) {
      final visitor = _RawReferences({'command', 'commandCurrent'});
      parseString(
        content: file.readAsStringSync(),
        path: file.path,
      ).unit.accept(visitor);
      violations.addAll(
        visitor.references.map((reference) => '${file.path}: $reference'),
      );
    }
    expect(violations, isEmpty);
    final control = _RawReferences({'command', 'commandCurrent'});
    parseString(
      content:
          "void example() { owner.command(null); owner.commandCurrent(null, {}, current); final invoke = owner.command; final invokeCurrent = (owner).commandCurrent; final implicit = command; final text = 'owner.command()'; }",
    ).unit.accept(control);
    expect(control.references, hasLength(5));
    final values = _RawReferences({'command', 'commandCurrent'});
    parseString(
      content:
          "void example(String command) { use(command, command: command); } void local() { final command = 'activate'; use(command); } /// [commandCurrent]\nvoid docs() {}",
    ).unit.accept(values);
    expect(values.references, isEmpty);

    final leaves = _RawReferences({
      'call',
      'stream',
      '_call',
      '_streamCurrent',
    });
    parseString(
      content: File(
        '${core.path}/lib/src/remote_domain.dart',
      ).readAsStringSync(),
    ).unit.accept(leaves);
    expect(_referenceCounts(leaves.references), _remoteTransportLeaves);
    for (final bypass in [
      'void command() { client.call(Operation.notesSave.wire); }',
      'void command() { final bypass = client.stream; }',
      'void command() { final bypass = _call; }',
      'void command() { _call(operation.wire); _call(operation.wire); }',
    ]) {
      final negative = _RawReferences({
        'call',
        'stream',
        '_call',
        '_streamCurrent',
      });
      parseString(
        content: 'class RemoteDomain { $bypass }',
      ).unit.accept(negative);
      expect(negative.references, isNotEmpty);
      expect(
        _referenceCounts([...leaves.references, ...negative.references]),
        isNot(_remoteTransportLeaves),
      );
    }
  });
  test(
    'optional reply metadata preserves explicit null and empty object presence',
    () {
      final rows = googleDriveFilesDescriptor.decodeResponse([
        {'id': 'null', 'parents': null, 'capabilities': null},
        {
          'id': 'empty',
          'parents': <String>[],
          'capabilities': <String, Object?>{},
        },
      ]);
      expect(rows.map((row) => row.toWire()).toList(), [
        {'id': 'null', 'parents': null, 'capabilities': null},
        {
          'id': 'empty',
          'parents': <String>[],
          'capabilities': <String, Object?>{},
        },
      ]);
      expect(
        audioCapabilitiesDescriptor.decodeResponse({'devices': null}).toWire(),
        {'devices': null},
      );
    },
  );
}
