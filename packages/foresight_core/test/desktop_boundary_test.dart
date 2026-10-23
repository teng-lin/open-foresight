import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:test/test.dart';

import 'support/boundary_analysis.dart';

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
      for (final directive in unit.directives.whereType<UriBasedDirective>()) {
        final uri = directive.uri.stringValue ?? '';
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
    expect(visited, contains(endsWith('/src/application_service.dart')));
    expect(violations, isEmpty);
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
      for (final directive in unit.directives.whereType<UriBasedDirective>()) {
        final uri = directive.uri.stringValue ?? '';
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
              'DesktopPresentation',
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
