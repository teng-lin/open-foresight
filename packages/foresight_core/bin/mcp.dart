import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:foresight_core/src/profile_paths.dart';
import 'package:foresight_core/src/service.dart';
import 'package:foresight_core/src/version.dart';

Future<void> main() async {
  ServiceConnection? client;
  try {
    client = ServiceConnection(ProfilePaths.resolve(Platform.environment));
    await client.connect();
    final connection = client;
    final server = McpServer(
      const Implementation(
        name: 'open-foresight',
        version: openForesightVersion,
      ),
      options: const McpServerOptions(
        capabilities: ServerCapabilities(tools: ServerCapabilitiesTools()),
      ),
    );
    final text = JsonSchema.string();
    final integer = JsonSchema.integer();
    Future<Object?> runOperation(
      String method,
      Map<String, dynamic> args,
      RequestHandlerExtra extra,
    ) async {
      if (extra.signal.aborted) throw StateError('Operation cancelled');
      final progressToken = extra.meta?['progressToken'];
      var progress = 0;
      Future<void> report(String message, {bool finished = false}) async {
        if (progressToken is! String && progressToken is! num) return;
        final value = progress++;
        await extra.sendNotification(
          JsonRpcProgressNotification(
            progressParams: ProgressNotification(
              progressToken: progressToken,
              progress: value,
              total: finished ? value : null,
              message: message,
            ),
          ),
        );
      }

      await report('Started');
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(report('Still working').catchError((Object _) {}));
      });
      final done = Completer<Object?>();
      Object? result;
      final subscription = connection
          .stream(method, args)
          .listen(
            (value) => result = value,
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
            onDone: () {
              if (!done.isCompleted) done.complete(result);
            },
          );
      final abort = extra.signal.onAbort.listen((_) {
        unawaited(subscription.cancel());
        if (!done.isCompleted)
          done.completeError(StateError('Operation cancelled'));
      });
      try {
        final value = await done.future;
        await report('Completed', finished: true);
        return value;
      } finally {
        timer.cancel();
        await abort.cancel();
        await subscription.cancel();
      }
    }

    void tool(
      String name,
      String operation,
      String description,
      Map<String, JsonSchema> properties,
      List<String> required, {
      bool readOnly = false,
      bool destructive = false,
      bool openWorld = false,
    }) {
      server.registerTool(
        name,
        description: description,
        inputSchema: JsonSchema.object(
          properties: properties,
          required: required,
          additionalProperties: false,
        ),
        annotations: ToolAnnotations(
          readOnlyHint: readOnly,
          destructiveHint: destructive,
          openWorldHint: openWorld,
        ),
        callback: (args, extra) async {
          try {
            final result = await runOperation(
              operation,
              Map<String, dynamic>.from(args),
              extra,
            );
            return CallToolResult(
              content: [TextContent(text: jsonEncode(result))],
              structuredContent: {'result': result},
            );
          } catch (error) {
            return CallToolResult(
              content: [TextContent(text: error.toString())],
              isError: true,
            );
          }
        },
      );
    }

    tool(
      'audio_capabilities',
      'audio.capabilities',
      'Inspect audio backend and permission state without requesting permission or starting capture.',
      {},
      [],
      readOnly: true,
    );
    tool(
      'audio_request_microphone',
      'audio.request_microphone',
      'Explicitly request microphone permission for the application service. May show macOS system consent UI; requires an interactive logged-in session.',
      {},
      [],
    );
    tool(
      'audio_request_system',
      'audio.request_system',
      'Explicitly request system audio recording consent for the application service. May show macOS consent UI; requires an interactive logged-in session. CoreAudio cannot verify authorization: completed or unknown does not prove permission or audible input. Inspect the returned message and settings guidance.',
      {},
      [],
    );
    tool(
      'get_status',
      'status',
      'Get local model readiness, indexing state, and active recording.',
      {},
      [],
      readOnly: true,
    );
    tool(
      'list_sources',
      'sources.list',
      'List active source metadata and revisions.',
      {},
      [],
      readOnly: true,
    );
    tool(
      'get_source',
      'sources.get',
      'Read a complete active source by ID.',
      {'id': text},
      ['id'],
      readOnly: true,
    );
    tool(
      'search',
      'sources.search',
      'Search indexed local knowledge. Returns passages, source IDs, titles, revisions, and scores.',
      {'query': text, 'limit': JsonSchema.integer(minimum: 1, maximum: 100)},
      ['query'],
      readOnly: true,
    );
    tool(
      'import_text',
      'sources.import',
      'Create or update a text source and index it. Supplying an existing ID replaces its content and increments its revision.',
      {'title': text, 'text': text, 'id': text},
      ['title', 'text'],
    );
    tool(
      'import_file',
      'sources.import_file',
      'Import and index a local UTF-8, PDF, or RTF file.',
      {'path': text},
      ['path'],
    );
    tool(
      'import_url',
      'sources.import_url',
      'Fetch and index an HTTP or HTTPS text/HTML page.',
      {
        'url': text,
        'allow_private_network': JsonSchema.boolean(
          description:
              'Explicitly permit local/private/special-use addresses for this import. Defaults to false.',
        ),
      },
      ['url'],
      openWorld: true,
    );
    tool(
      'import_directory',
      'sources.import_directory',
      'Import supported text, Markdown, PDF, and RTF files recursively from a local directory.',
      {'path': text},
      ['path'],
    );
    tool(
      'refresh_sources',
      'sources.refresh',
      'Refresh imported sources and connected Google sources, then update the index.',
      {
        'allow_private_network': JsonSchema.boolean(
          description:
              'Explicitly permit private network URL refreshes for this request. Defaults to false.',
        ),
      },
      [],
      openWorld: true,
    );
    tool(
      'delete_source',
      'sources.delete',
      'Delete a source from the application and search index.',
      {'id': text},
      ['id'],
      destructive: true,
    );
    tool(
      'list_notes',
      'notes.list',
      'Read saved personal notes.',
      {},
      [],
      readOnly: true,
    );
    tool(
      'save_note',
      'notes.save',
      'Create a personal note or update an existing note by ID.',
      {'id': integer, 'title': text, 'body': text},
      ['title', 'body'],
    );
    tool(
      'list_meetings',
      'meetings.list',
      'List meetings and their states.',
      {},
      [],
      readOnly: true,
    );
    tool(
      'create_meeting',
      'meetings.create',
      'Create a meeting without starting audio capture.',
      {'title': text},
      ['title'],
    );
    tool(
      'get_meeting',
      'meetings.get',
      'Read meeting notes, transcript segments, and generated/edited artifacts.',
      {'id': integer},
      ['id'],
      readOnly: true,
    );
    tool(
      'save_meeting_notes',
      'meetings.notes',
      'Save original meeting notes. Live enhancement uses final transcript evidence when enabled.',
      {'id': integer, 'body': text},
      ['id', 'body'],
    );
    tool(
      'import_transcript',
      'meetings.transcript',
      'Append a final transcript segment and index the meeting.',
      {
        'id': integer,
        'text': text,
        'start': integer,
        'end': integer,
        'source': text,
      },
      ['id', 'text'],
    );
    tool(
      'generate_meeting_artifact',
      'meetings.generate',
      'Generate a summary or actions from final transcript evidence using the configured local model.',
      {
        'id': integer,
        'kind': JsonSchema.string(enumValues: ['summary', 'actions']),
      },
      ['id', 'kind'],
    );
    tool(
      'enhance_meeting_notes',
      'meetings.enhance',
      'Generate an enhanced version of original meeting notes using final transcript evidence.',
      {'id': integer},
      ['id'],
    );
    tool(
      'edit_artifact',
      'artifacts.edit',
      'Save an edited version of a meeting artifact while retaining its generated text.',
      {'id': integer, 'text': text},
      ['id', 'text'],
    );
    tool(
      'start_recording',
      'meetings.start',
      'Start microphone and playback recording for a meeting. Only one meeting can record per profile.',
      {'id': integer},
      ['id'],
    );
    tool(
      'pause_recording',
      'meetings.pause',
      'Pause microphone and playback capture, retaining pre-pause transcription. An optional meeting ID guards ownership.',
      {'id': integer},
      [],
    );
    tool(
      'resume_recording',
      'meetings.resume',
      'Resume a paused recording with the same audio routes and transcript timeline.',
      {'id': integer},
      [],
    );
    tool(
      'stop_recording',
      'meetings.stop',
      'Stop the current recording, finish transcription, and index final transcript evidence.',
      {},
      [],
    );
    server.registerTool(
      'ask',
      description:
          'Generate a grounded, cited answer from indexed local sources. Uses the shared local generation worker.',
      inputSchema: JsonSchema.object(
        properties: {'question': text},
        required: ['question'],
        additionalProperties: false,
      ),
      callback: (args, extra) async {
        try {
          final result = await runOperation('answer.stream', {
            'question': args['question'],
          }, extra);
          return CallToolResult(
            content: [TextContent(text: result as String)],
            structuredContent: {'answer': result},
          );
        } catch (e) {
          return CallToolResult(
            content: [TextContent(text: e.toString())],
            isError: true,
          );
        }
      },
    );
    final transport = StdioServerTransport();
    final done = Completer<void>();
    server.server.onclose = () {
      if (!done.isCompleted) done.complete();
    };
    await server.connect(transport);
    await done.future;
    await connection.close();
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    await client?.close();
    exitCode = 1;
  }
}
