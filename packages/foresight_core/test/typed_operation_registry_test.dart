import 'dart:async';

import 'package:foresight_core/src/operation_descriptor.dart';
import 'package:foresight_core/src/operation_registry.dart';
import 'package:foresight_core/src/operation_requests.dart';
import 'package:foresight_core/src/operations.dart';
import 'package:foresight_core/src/rpc_error.dart';
import 'package:test/test.dart';

Iterable<OperationHandler> handlers(
  OperationScope scope, {
  Map<Operation, OperationHandler> replacements = const {},
}) => Operation.values
    .where((operation) => operation.descriptor.scope == scope)
    .map(
      (operation) =>
          replacements[operation] ??
          TypedOperationHandler<OperationRequest>(
            operation,
            (request, {current}) => request.operation.wire,
          ),
    );

void main() {
  test('application and service ownership is exhaustive and disjoint', () {
    final application = OperationRegistry(
      OperationScope.application,
      handlers(OperationScope.application),
    );
    final service = OperationRegistry(
      OperationScope.service,
      handlers(OperationScope.service),
    );
    expect(application.operations, hasLength(94));
    expect(service.operations, {
      Operation.answerStream,
      Operation.googleSignIn,
      Operation.googleAddAccount,
      Operation.securityAttachDesktop,
      Operation.securityDetachDesktop,
      Operation.securityDesktopVisibility,
      Operation.securityDecide,
      Operation.securityAllowImportRoot,
      Operation.serviceStopIfIdle,
    });
    expect(application.operations.intersection(service.operations), isEmpty);
    expect(
      application.operations.union(service.operations),
      Operation.values.toSet(),
    );
    expect(() => application.operations.clear(), throwsUnsupportedError);
  });

  test(
    'registration rejects missing, duplicate and foreign-owner handlers',
    () {
      expect(
        () => OperationRegistry(OperationScope.application, []),
        throwsArgumentError,
      );
      expect(
        () => OperationRegistry(OperationScope.application, [
          ...handlers(OperationScope.application),
          TypedOperationHandler<NotesSaveRequest>(
            Operation.notesSave,
            (request, {current}) => null,
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => OperationRegistry(OperationScope.application, [
          ...handlers(OperationScope.application),
          TypedOperationHandler<AnswerStreamRequest>(
            Operation.answerStream,
            (request, {current}) => null,
          ),
        ]),
        throwsArgumentError,
      );
    },
  );

  test(
    'concrete handlers receive typed fields, original context and cancellation',
    () async {
      var live = true;
      bool current() => live;
      final request = decodeOperationRequest(Operation.notesSave, {
        'id': 7,
        'title': 'title',
        'body': 'body',
        'idempotency_key': 'key',
      });
      final registry = OperationRegistry(
        OperationScope.application,
        handlers(
          OperationScope.application,
          replacements: {
            Operation.notesSave: TypedOperationHandler<NotesSaveRequest>(
              Operation.notesSave,
              (note, {current}) async {
                expect(note, same(request));
                expect([note.id, note.title, note.body], [7, 'title', 'body']);
                expect(note.context.idempotencyKey, 'key');
                expect(current?.call(), isTrue);
                await Future<void>.value();
                live = false;
                expect(current?.call(), isFalse);
                return {'id': note.id};
              },
            ),
          },
        ),
      );
      expect(await registry.dispatch(request, current: current), {'id': 7});
    },
  );

  test('wrong generic registration is an internal wiring failure', () async {
    var invoked = false;
    final registry = OperationRegistry(
      OperationScope.application,
      handlers(
        OperationScope.application,
        replacements: {
          Operation.notesSave: TypedOperationHandler<MeetingsCreateRequest>(
            Operation.notesSave,
            (request, {current}) {
              invoked = true;
              return null;
            },
          ),
        },
      ),
    );
    await expectLater(
      registry.dispatch(
        decodeOperationRequest(Operation.notesSave, {
          'title': 't',
          'body': 'b',
        }),
      ),
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.internal,
        ),
      ),
    );
    expect(invoked, isFalse);
    final mismatched = TypedOperationHandler<NotesSaveRequest>(
      Operation.meetingsCreate,
      (request, {current}) => null,
    );
    expect(
      () => mismatched.invoke(
        decodeOperationRequest(Operation.notesSave, {
          'title': 't',
          'body': 'b',
        }),
      ),
      throwsA(
        isA<RpcError>().having(
          (error) => error.code,
          'code',
          RpcErrorCode.internal,
        ),
      ),
    );
  });

  test('application dispatch still refuses service-only requests', () async {
    final registry = OperationRegistry(
      OperationScope.application,
      handlers(OperationScope.application),
    );
    await expectLater(
      registry.dispatch(
        decodeOperationRequest(Operation.answerStream, {'question': 'why?'}),
      ),
      throwsA(
        isA<RpcError>()
            .having((error) => error.code, 'code', RpcErrorCode.invalidArgument)
            .having(
              (error) => error.message,
              'message',
              'Operation requires service dispatch: answer.stream',
            ),
      ),
    );
  });

  test(
    'registry preserves thrown handler errors for execution-layer mapping',
    () async {
      final deliberate = StateError('handler failed');
      final registry = OperationRegistry(
        OperationScope.application,
        handlers(
          OperationScope.application,
          replacements: {
            Operation.notesList: TypedOperationHandler<NotesListRequest>(
              Operation.notesList,
              (request, {current}) => throw deliberate,
            ),
          },
        ),
      );
      await expectLater(
        registry.dispatch(decodeOperationRequest(Operation.notesList, {})),
        throwsA(same(deliberate)),
      );
    },
  );

  test(
    'stream subscription and underlying cleanup stay owned by service',
    () async {
      var listens = 0, cancels = 0;
      final controller = StreamController<Object?>(
        onListen: () => listens++,
        onCancel: () => cancels++,
      );
      final stream = controller.stream;
      final registry = OperationRegistry(
        OperationScope.service,
        handlers(
          OperationScope.service,
          replacements: {
            Operation.answerStream: TypedOperationHandler<AnswerStreamRequest>(
              Operation.answerStream,
              (request, {current}) => stream,
            ),
          },
        ),
      );
      final returned = await registry.dispatch(
        decodeOperationRequest(Operation.answerStream, {'question': 'why?'}),
      );
      expect(returned, same(stream));
      expect(listens, 0);
      final subscription = (returned as Stream<Object?>).listen((_) {});
      expect(listens, 1);
      await subscription.cancel();
      expect(cancels, 1);
      await controller.close();
    },
  );
}
