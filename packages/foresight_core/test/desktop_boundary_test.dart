import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:test/test.dart';

void main() {
  final package = Directory.current.absolute;
  final desktop = Directory('${package.path}/../../apps/desktop/lib');

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
      final contexts = AnalysisContextCollection(
        includedPaths: ['${package.path}/lib'],
      );
      addTearDown(contexts.dispose);
      final forbidden = RegExp(
        r'^(Store|Helper|Domain|RemoteDomain|RemoteHelper|NativeRuntime|NativeConversation|Recording|ServiceClient|RagServiceClient|HelperChannel|HelperTransportConnector|GraphPersistence|MeetingWorkflowStore|Database|RuntimeConfiguration|GoogleAuth|GoogleConnections|SecretStore|PlatformSecretStore|configureGeneration|configureSpeech|configureDedicatedQuery|configureEncryptedDedicatedQuery|registerInstalledModels|retrieveAnswerPassages)$',
      );
      for (final entry in ['desktop.dart', 'desktop_bootstrap.dart']) {
        final path = '${package.path}/lib/$entry';
        final result = await contexts
            .contextFor(path)
            .currentSession
            .getResolvedLibrary(path);
        expect(result, isA<ResolvedLibraryResult>());
        final names = (result as ResolvedLibraryResult)
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
              'StoreReader',
              'HelperStatus',
              'SourceSummary',
              'ReadQuery',
              'ReadResult',
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
