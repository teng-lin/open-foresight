part of 'application.dart';

extension ApplicationPreparation on Application {
  Future<void> prepareMeeting(
    int id,
    List<String> sourceIds, {
    String? requestId,
    bool Function()? current,
  }) async {
    if (sourceIds.isEmpty ||
        sourceIds.length > 100 ||
        sourceIds.toSet().length != sourceIds.length) {
      throw ArgumentError('Select between one and 100 distinct documents');
    }
    final sources = <Map<String, Object?>>[];
    for (final sourceId in sourceIds) {
      final source = store.rows(
        'SELECT * FROM sources WHERE id=? AND deleted=0',
        [sourceId],
      ).firstOrNull;
      if (source == null) {
        throw RpcError(
          RpcErrorCode.notFound,
          'Selected document no longer exists',
        );
      }
      if (sourceId.startsWith('meeting-preparation-')) {
        throw ArgumentError('A preparation brief cannot be its own source');
      }
      sources.add(source);
    }
    final meeting = _meeting(id);
    final event = store.rows(
      'SELECT metadata FROM calendar_events WHERE meeting_id=?',
      [id],
    ).firstOrNull?['metadata'];
    void checkSources() {
      for (final source in sources) {
        final row = store.rows(
          'SELECT revision,deleted FROM sources WHERE id=?',
          [source['id']],
        ).firstOrNull;
        if (row == null ||
            row['deleted'] != 0 ||
            row['revision'] != source['revision']) {
          throw RpcError(
            RpcErrorCode.cancelled,
            'Preparation document changed; regenerate',
          );
        }
      }
      if (_meeting(id)['title'] != meeting['title'] ||
          store.rows(
                'SELECT metadata FROM calendar_events WHERE meeting_id=?',
                [id],
              ).firstOrNull?['metadata'] !=
              event) {
        throw RpcError(
          RpcErrorCode.cancelled,
          'Meeting event changed; regenerate',
        );
      }
    }

    await _meetingWorkflow<void>(
      id,
      'preparation',
      requestId: requestId,
      current: current,
      checkInputs: checkSources,
      execute: (run) async {
        final fingerprint = summaryDigest(
          jsonEncode([
            run.identity,
            meeting['title'],
            event,
            (sources
                .map(
                  (source) =>
                      '${source['id']}:${source['revision']}:${summaryDigest(source['content'] as String)}',
                )
                .toList()
              ..sort()),
          ]),
        );
        final latest = store.meetingArtifacts(id, 'preparation').firstOrNull;
        final manifest = latest?['manifest'];
        if (latest?['edited'] == null && manifest is String) {
          if ((jsonDecode(manifest) as Map)['fingerprint'] == fingerprint) {
            return;
          }
        }
        final summaries = <String>[],
            errors = <Map<String, String>>[],
            cache = <List<Object?>>[];
        var clipped = false;
        for (var i = 0; i < sources.length; i++) {
          run.check();
          final source = sources[i];
          final key = summaryDigest(
            jsonEncode([
              preparationVersion,
              run.identity,
              source['id'],
              source['revision'],
              source['title'],
              summaryDigest(source['content'] as String),
            ]),
          );
          try {
            final cached = store.rows(
              'SELECT body,clipped FROM document_summary_cache WHERE cache_key=?',
              [key],
            ).firstOrNull;
            if (cached?['clipped'] == 1) clipped = true;
            var body = cached?['body'] as String?;
            if (body == null) {
              final result = await summarizePreparationDocument(
                source['content'] as String,
                complete: run.complete,
                checkCurrent: run.check,
                onProgress: run.progress,
                context: run.context,
                output: run.output,
              );
              body = result.body;
              clipped |= result.clipped;
              cache.add([
                key,
                source['id'],
                source['revision'],
                body,
                run.identity,
                result.clipped ? 1 : 0,
              ]);
            }
            if (body.isNotEmpty) {
              summaries.add('Document ${i + 1}: ${source['title']}\n$body');
            }
          } catch (error) {
            run.check(); // Cancellation/stale input cannot become partial success.
            errors.add({
              'id': source['id'] as String,
              'title': source['title'] as String,
              'error': error.toString(),
            });
          }
          run.progress(
            SummaryProgress(
              'documents',
              completed: i + 1,
              total: sources.length,
            ),
          );
        }
        if (summaries.isEmpty) {
          throw StateError(
            'No document summaries available${errors.isEmpty ? '' : ': ${errors.map((error) => error['error']).join('; ')}'}',
          );
        }
        var body = summaries.singleOrNull ?? '';
        if (summaries.length > 1) {
          final prefix =
              '$preparationSynthesisInstructions\n\nMeeting context: ${jsonEncode({'title': meeting['title'], 'event': event})}\n\n';
          final joined = fitWorkflowPartials(
            summaries,
            system: documentSummaryInstructions,
            prefix: prefix,
            context: run.context,
            output: run.output,
          );
          clipped |= joined.clipped;
          run.progress(const SummaryProgress('synthesizing'));
          body = await run.complete(
            '$prefix${joined.text}',
            documentSummaryInstructions,
            (text) =>
                run.progress(SummaryProgress('synthesizing', preview: text)),
          );
        }
        if (errors.isNotEmpty) {
          body +=
              '\n\n## Unavailable documents\n${errors.map((error) => '- ${error['title']}').join('\n')}';
        }
        run.check();
        final source = store.workflowTransaction(() {
          for (final row in cache) {
            store.db.execute(
              'INSERT OR REPLACE INTO document_summary_cache VALUES(?,?,?,?,?,?)',
              row,
            );
          }
          return store.saveWorkflowArtifact(
            id,
            'preparation',
            body,
            run.model,
            run.revision,
            {
              'version': preparationVersion,
              'identity': run.identity,
              'fingerprint': fingerprint,
              'sources': [
                for (final source in sources)
                  {'id': source['id'], 'revision': source['revision']},
              ],
              'errors': errors,
              'degraded': errors.isNotEmpty,
              'reduction_clipped': clipped,
            },
          );
        });
        _indexWorkflowSource(source);
      },
    );
  }
}
