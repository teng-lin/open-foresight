import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:test/test.dart';

import 'support/boundary_analysis.dart';

Iterable<String> dependencyUris(CompilationUnit unit) sync* {
  for (final directive in unit.directives.whereType<UriBasedDirective>()) {
    yield directive.uri.stringValue ?? '';
    if (directive is ImportDirective) {
      for (final configuration in directive.configurations) {
        yield configuration.uri.stringValue ?? '';
      }
    } else if (directive is ExportDirective) {
      for (final configuration in directive.configurations) {
        yield configuration.uri.stringValue ?? '';
      }
    }
  }
}

Set<String> importClosure(Directory package, List<File> pending) {
  final visited = <String>{};
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    if (!visited.add(file.absolute.path)) continue;
    final unit = parseString(
      content: file.readAsStringSync(),
      path: file.path,
    ).unit;
    for (final uri in dependencyUris(unit)) {
      if (uri.startsWith('package:foresight_core/')) {
        pending.add(
          File('${package.path}/lib/${uri.split('/').skip(1).join('/')}'),
        );
      } else if (!uri.contains(':')) {
        pending.add(File.fromUri(file.uri.resolve(uri)));
      }
    }
  }
  return visited;
}

void main() {
  final package = Directory.current.absolute;
  final desktop = Directory('${package.path}/../../apps/desktop/lib');

  test('desktop import closure does not reach the MCP implementation', () {
    final pending = [
      File('${package.path}/lib/desktop.dart'),
      File('${package.path}/lib/desktop_bootstrap.dart'),
    ];
    final visited = <String>{};
    final violations = <String>[];
    while (pending.isNotEmpty) {
      final file = pending.removeLast();
      if (!visited.add(file.absolute.path)) continue;
      final unit = parseString(
        content: file.readAsStringSync(),
        path: file.path,
      ).unit;
      for (final uri in dependencyUris(unit)) {
        if (uri.startsWith('package:mcp_dart/')) {
          violations.add('${file.path}: $uri');
        } else if (uri.startsWith('package:foresight_core/')) {
          pending.add(
            File('${package.path}/lib/${uri.split('/').skip(1).join('/')}'),
          );
        } else if (!uri.contains(':')) {
          pending.add(File.fromUri(file.uri.resolve(uri)));
        }
      }
    }
    expect(visited, contains(endsWith('/src/remote_domain.dart')));
    expect(visited, isNot(contains(endsWith('/src/application_service.dart'))));
    expect(visited, isNot(contains(endsWith('/src/google_auth.dart'))));
    expect(visited, isNot(contains(endsWith('/src/model_setup.dart'))));
    expect(violations, isEmpty);
  });

  test('desktop and MCP closures exclude authority and mutation modules', () {
    for (final entry in [
      'lib/desktop.dart',
      'lib/desktop_bootstrap.dart',
      'bin/mcp.dart',
    ]) {
      final visited = importClosure(package, [File('${package.path}/$entry')]);
      for (final name in [
        'store.dart',
        'native.dart',
        'recording.dart',
        'domain.dart',
        'application.dart',
        'application_service.dart',
        'service_frontend.dart',
        'google_auth.dart',
        'google_connections.dart',
        'model_setup.dart',
        'persistence/source_store.dart',
        'persistence/meeting_store.dart',
        'persistence/model_store.dart',
        'persistence/label_store.dart',
        'persistence/schema_migrations.dart',
        'persistence/conversation_queries.dart',
      ]) {
        expect(
          visited,
          isNot(contains(endsWith('/src/$name'))),
          reason: '$entry: $name',
        );
      }
      if (entry == 'lib/desktop_bootstrap.dart') {
        expect(
          visited,
          contains(endsWith('/src/persistence/sqlite_snapshot_source.dart')),
          reason:
              'Desktop keeps the deliberately read-only SQLite snapshot path',
        );
      }
    }
  });

  test('presentation values have no service or mutation import closure', () {
    final pending = [
      for (final name in [
        'output_calendar.dart',
        'granola_return_failure.dart',
        'graph_view_data.dart',
        'model_setup_status.dart',
        'speech_model_catalog.dart',
        'dedicated_query_terms.dart',
      ])
        File('${package.path}/lib/src/$name'),
    ];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final file = pending.removeLast();
      if (!visited.add(file.absolute.path)) continue;
      final unit = parseString(content: file.readAsStringSync()).unit;
      for (final uri in dependencyUris(unit)) {
        if (!uri.contains(':')) {
          pending.add(File.fromUri(file.uri.resolve(uri)));
        }
      }
    }
    for (final name in [
      'store.dart',
      'native.dart',
      'google_auth.dart',
      'model_setup.dart',
      'application.dart',
      'application_service.dart',
      'domain.dart',
      'speech_models.dart',
      'dedicated_query_acquisition.dart',
    ]) {
      expect(visited, isNot(contains(endsWith('/src/$name'))), reason: name);
    }
  });

  test('persistence uses shared filesystem and read primitives', () {
    for (final name in ['sqlite_preflight.dart', 'source_store.dart']) {
      final file = File('${package.path}/lib/src/persistence/$name');
      final unit = parseString(content: file.readAsStringSync()).unit;
      final dependencies = unit.directives.whereType<UriBasedDirective>().map(
        (directive) => directive.uri.stringValue ?? '',
      );
      expect(dependencies, isNot(contains('../service_socket.dart')));
      expect(dependencies, isNot(contains('../operations.dart')));
    }
  });

  test('production desktop imports only the curated core entry points', () {
    final violations = <String>[];
    for (final file in desktop.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final relative = file.path.substring(desktop.path.length + 1);
      final unit = parseString(
        content: file.readAsStringSync(),
        path: file.path,
      ).unit;
      for (final uri in dependencyUris(unit)) {
        if (uri.startsWith('package:foresight_core/')) {
          final valid =
              uri == 'package:foresight_core/desktop.dart' ||
              (uri == 'package:foresight_core/desktop_bootstrap.dart' &&
                  relative == 'main.dart');
          if (!valid) violations.add('$relative: $uri');
        }
        if ([
              'grpc',
              'http2',
              'sqlite3',
              'ffi',
              'protobuf',
            ].any((name) => uri.startsWith('package:$name/')) ||
            uri == 'dart:ffi') {
          violations.add('$relative: $uri');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'Widgets must not obtain writer/native/helper transports through imports or proxy exports.',
    );
  });

  test(
    'curated public namespaces do not export implementation capabilities',
    () async {
      // Referenced libraries still participate in transitive export linking.
      final contexts = desktopBoundaryContexts(package);
      addTearDown(contexts.dispose);
      final forbidden = RegExp(
        r'^(Store|Helper|Domain|RemoteDomain|RemoteHelper|NativeRuntime|NativeConversation|Recording|ServiceClient|RagServiceClient|HelperChannel|HelperTransportConnector|GraphPersistence|MeetingWorkflowStore|Database|RuntimeConfiguration|GoogleAuth|GoogleConnections|SecretStore|PlatformSecretStore|configureGeneration|configureSpeech|configureDedicatedQuery|configureEncryptedDedicatedQuery|registerInstalledModels|retrieveAnswerPassages)$',
      );
      for (final entry in desktopBoundaryEntries) {
        final path = '${package.path}/lib/$entry';
        final session = contexts.contextFor(path).currentSession;
        final uri = session.uriConverter.pathToUri(path);
        expect(
          uri,
          isNotNull,
          reason: '$entry must retain its exact file binding',
        );
        // Only linked export elements are needed; avoid requesting full
        // analysis of this target library.
        final result = await session.getLibraryByUri(uri!.toString());
        expect(result, isA<LibraryElementResult>());
        final names = (result as LibraryElementResult)
            .element
            .exportNamespace
            .definedNames2
            .keys
            .toSet();
        expect(
          names.where(forbidden.hasMatch),
          isEmpty,
          reason: '$entry must expose only its intended capabilities',
        );
        if (entry == 'desktop.dart') {
          expect(
            names,
            containsAll([
              'DesktopConnection',
              'GenerationPresentationValue',
              'CapturePresentation',
              'GooglePresentation',
              'GenerationPresentation',
              'StoreReader',
              'HelperStatus',
              'SourceSummary',
              'ReadQuery',
              'ReadResult',
              'OutputStatsPeriod',
              'OutputStatsWeek',
              'AnswerScopeSnapshot',
              'StoreReadQueries',
              'Operation',
            ]),
          );
          expect(names, isNot(contains('ProfilePaths')));
          expect(names, isNot(contains('runtimeConfiguration')));
        } else {
          expect(names, containsAll(['ProfilePaths', 'connectDesktop']));
        }
      }
    },
  );
}
