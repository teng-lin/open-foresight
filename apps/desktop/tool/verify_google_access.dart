import 'dart:convert';
import 'dart:io';
import 'package:open_foresight/google_auth.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3)
    throw ArgumentError('SOURCE_GOOGLE_DIRECTORY BUNDLED_CLIENT REPORT');
  final source = Directory(arguments[0]);
  final reportFile = File(arguments[2]);
  final temporary = Directory.systemTemp.createTempSync(
    'foresight-google-readonly-',
  );
  await Process.run('chmod', ['700', temporary.path]);
  GoogleAuth? auth;
  final report = <String, Object?>{
    'verified_at': DateTime.now().toUtc().toIso8601String(),
    'method':
        'Current GoogleAuth implementation; temporary copy of existing Linux authorization; bounded live read-only API calls',
    'original_profile_written': false,
    'privacy':
        'No item/account identifiers, titles, content, tokens or client secret retained',
  };
  try {
    for (final name in ['client.json', 'tokens.json']) {
      final file = File('${source.path}/$name');
      if (file.existsSync()) {
        final copy = await file.copy('${temporary.path}/$name');
        await Process.run('chmod', ['600', copy.path]);
      }
    }
    auth = GoogleAuth(temporary, defaultClient: File(arguments[1]));
    if (!auth.connected) {
      report['status'] = 'authorization_unavailable';
      exitCode = 1;
    } else {
      final drive = await auth.apiJson(
        auth.endpoints.drive
            .resolve('files')
            .replace(
              queryParameters: {
                'pageSize': '1',
                'fields': 'files(id),nextPageToken',
                'q': 'trashed = false',
              },
            ),
      );
      final calendar = await auth.apiJson(
        auth.endpoints.calendar
            .resolve('calendars/primary/events')
            .replace(
              queryParameters: {
                'maxResults': '1',
                'fields': 'items(id),nextPageToken',
              },
            ),
      );
      report.addAll({
        'status': 'passed',
        'drive_files_list_passed': true,
        'drive_sample_count': (drive['files'] as List).length,
        'calendar_events_list_passed': true,
        'calendar_sample_count': (calendar['items'] as List).length,
        'limitation':
            'Read access only; original browser consent and extraction/import/retrieval/reminder behaviors have separate retained acceptance',
      });
    }
  } catch (_) {
    report['status'] = 'live_access_failed';
    exitCode =
        1; // Do not expose provider errors containing private response data.
  } finally {
    await auth?.close();
    temporary.deleteSync(recursive: true);
    report['temporary_credentials_removed'] = !temporary.existsSync();
    reportFile.parent.createSync(recursive: true);
    reportFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    stdout.writeln(jsonEncode(report));
  }
}
