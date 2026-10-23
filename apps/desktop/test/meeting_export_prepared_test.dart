import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foresight_core/desktop.dart';
import 'package:open_foresight/features/meetings/meeting_export.dart';
import 'package:open_foresight/generated_content.dart';

class _Reader implements StoreReader {
  final replies = <Completer<ReadResult<List<ExportNote>>>>[];
  @override
  Future<ReadResult<T>> read<T>(ReadQuery<T> query) {
    expect(query.key, StoreReadQueries.exportNotes().key);
    final reply = Completer<ReadResult<List<ExportNote>>>();
    replies.add(reply);
    return reply.future.then((result) => result.asType<T>());
  }

  void complete(
    int index, {
    String? title = 'Prepared export',
    bool fail = false,
  }) => replies[index].complete(
    ReadResult(
      freshness: fail ? ReadFreshness.failed : ReadFreshness.current,
      value: fail
          ? null
          : [
              ExportNote.fromRow({
                'id': 1,
                'title': title,
                'body': 'Saved notes',
                'export_date': DateTime(2026, 10, 16).millisecondsSinceEpoch,
              }),
            ],
      error: fail
          ? RpcError(RpcErrorCode.unavailable, 'export read unavailable')
          : null,
      requestTag: 'export',
      sequence: index,
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected synchronous export projection ${invocation.memberName}',
  );
}

void main() {
  testWidgets(
    'export renders prepared values and ordinary builds admit no reads',
    (tester) async {
      final reader = _Reader();
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) {
              rebuild = update;
              return MeetingExportDialog(
                store: reader,
                now: DateTime(2026, 10, 16),
                save: (_) async => true,
              );
            },
          ),
        ),
      );
      expect(reader.replies, hasLength(1));
      expect(find.text('Loading saved notes…'), findsOneWidget);
      reader.complete(0);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<GeneratedContent>(
              find.byKey(const ValueKey('meeting-export-preview')),
            )
            .markdown,
        contains('Prepared export'),
      );
      for (var i = 0; i < 5; i++) {
        rebuild(() {});
        await tester.pump();
      }
      expect(
        reader.replies,
        hasLength(1),
        reason:
            'The preview composes its captured typed notes without StoreReader projections',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a failed export read is visible and a normal filter action retries',
    (tester) async {
      final reader = _Reader();
      await tester.pumpWidget(
        MaterialApp(
          home: MeetingExportDialog(
            store: reader,
            now: DateTime(2026, 10, 16),
            save: (_) async => true,
          ),
        ),
      );
      reader.complete(0, fail: true);
      await tester.pumpAndSettle();
      expect(find.textContaining('export read unavailable'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Download markdown'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byIcon(Icons.filter_list));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(reader.replies, hasLength(2));
      reader.complete(1);
      await tester.pumpAndSettle();
      expect(find.textContaining('export read unavailable'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Download markdown'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final boundary in ['disposal', 'owner replacement']) {
    testWidgets('held export read after $boundary cannot publish or save', (
      tester,
    ) async {
      final reader = _Reader();
      var current = true, saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MeetingExportDialog(
            store: reader,
            now: DateTime(2026, 10, 16),
            current: () => current,
            save: (_) async {
              saves++;
              return true;
            },
          ),
        ),
      );
      if (boundary == 'disposal') {
        await tester.pumpWidget(const SizedBox());
      } else {
        current = false;
      }
      reader.complete(0, title: 'Retired export');
      await tester.pumpAndSettle();
      expect(find.textContaining('Retired export'), findsNothing);
      expect(find.byType(GeneratedContent), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
