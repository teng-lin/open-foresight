/// Run this executable from reviewed main after the initial bootstrap merge.
/// Bootstrap alone uses the new candidate executable, reviewed with its negative
/// tests, against independently supplied reviewed-main source, never local hashes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:crypto/crypto.dart';

const migrationPath =
    'packages/foresight_core/lib/src/persistence/schema_migrations.dart';
const manifestPath =
    'packages/foresight_core/lib/src/persistence/migration_manifest.json';
const fixturePath =
    'packages/foresight_core/test/fixtures/persistence-c28a1561';

// These are reviewed lexical bindings, not arbitrary replacement rules supplied
// by a candidate. Candidate isolation below proves each maps to a declaration in
// the frozen module, rather than to a live Store/graph implementation.
const historicalBindings = {
  '_documentLabels': 'documentLabels',
  '_HistoricalDocumentLabel': 'DocumentLabel',
  '_historicalGraphLabelPalette': 'graphLabelPalette',
  '_historicalAllocateGraphLabelColor': 'allocateGraphLabelColor',
};

// Explicit closure inventory avoids treating local variables/parameters named
// `labels` as calls to Store.labels. Each whole definition includes signatures,
// defaults, class fields, factory/ordinary constructors and constants.
const migrationClosures = <int, List<String>>{
  1: ['_createLegacyTables'],
  2: ['_createLegacyTables'],
  3: ['_migrateNoteHistory'],
  4: ['_migrateModelMetadata'],
  5: ['_migrateSourceUris', '_legacySourceUri', 'rows'],
  6: ['_migrateAnswerHistory'],
  7: ['_migrateMeetingQuestions'],
  8: ['_migrateGoogleTables'],
  9: [
    '_reconcileLabelRecords',
    '_storedLabelNames',
    '_writeLabelRecords',
    'documentLabels',
    'rows',
    'DocumentLabel',
    'allocateGraphLabelColor',
    'graphLabelPalette',
  ],
  10: [],
  11: ['rows'],
  12: ['rows'],
  13: [],
  14: ['rows'],
  15: [],
  16: ['_restoreGoogleModificationTimes', 'rows'],
  18: ['_createContentHistory'],
  19: ['rows'],
  20: ['_boundContentHistory', 'rows'],
  21: ['_routeBackupErasure'],
  22: ['_createMeetingIndex'],
  24: ['_createRecordingAudio'],
  25: [
    '_createMeetingAttribution',
    '_attributionRevisionBump',
    '_attributionReproject',
  ],
  23: [
    '_migratePreferenceEntities',
    '_legacyPreferenceEntityKey',
    '_legacyEntityInteger',
    '_moveLegacyPreferenceEntity',
    'rows',
  ],
  17: [
    '_canonicalizeLabels',
    'rows',
    'documentLabels',
    'DocumentLabel',
    'allocateGraphLabelColor',
    'graphLabelPalette',
  ],
};

Never reject(String message) =>
    throw StateError('Migration integrity: $message');
String digest(List<int> bytes) => sha256.convert(bytes).toString();

List<String> canonicalTokens(AstNode node, {bool frozen = false}) {
  final result = <String>[];
  // Documentation comments have their own token chain. Starting there can
  // hash only the comment and omit the entire executable definition. Preserve
  // metadata annotations, but start after comments on annotated declarations.
  Token? token = node is AnnotatedNode
      ? (node.metadata.isEmpty
            ? node.firstTokenAfterCommentAndMetadata
            : node.metadata.first.beginToken)
      : node.beginToken;
  while (token != null &&
      !token.isEof &&
      token.offset <= node.endToken.offset) {
    result.add(
      frozen ? historicalBindings[token.lexeme] ?? token.lexeme : token.lexeme,
    );
    token = token.next;
  }
  return result;
}

CompilationUnit parseFile(File file) {
  if (!file.existsSync()) reject('missing source ${file.path}');
  final parsed = parseString(content: file.readAsStringSync(), path: file.path);
  if (parsed.errors.isNotEmpty) {
    reject('invalid Dart source ${file.path}: ${parsed.errors}');
  }
  return parsed.unit;
}

class MigrationSource {
  final Map<int, Map<String, Object?>> entries;
  final bool frozen;
  final int versionCount;
  MigrationSource(this.entries, this.frozen, this.versionCount);

  factory MigrationSource.read(Directory root, {required bool requireFrozen}) {
    final frozenFile = File('${root.path}/$migrationPath');
    final frozen = frozenFile.existsSync();
    if (requireFrozen && !frozen) {
      reject('candidate has no isolated migration module');
    }
    final sourcePath = frozen
        ? migrationPath
        : 'packages/foresight_core/lib/src/store.dart';
    final unit = parseFile(File('${root.path}/$sourcePath'));
    final ownerName = frozen ? 'ApplicationMigrations' : 'Store';
    final owners = unit.declarations
        .whereType<ClassDeclaration>()
        .where((node) => node.namePart.typeName.lexeme == ownerName)
        .toList();
    if (owners.length != 1) reject('expected one $ownerName in $sourcePath');
    final owner = owners.single;
    if (frozen) _verifyIsolation(unit, owner);
    final symbols = <String, AstNode>{};
    void add(String name, AstNode node) {
      final key = frozen ? historicalBindings[name] ?? name : name;
      if (symbols.containsKey(key)) reject('ambiguous frozen binding $key');
      symbols[key] = node;
    }

    for (final method in owner.body.members.whereType<MethodDeclaration>()) {
      add(method.name.lexeme, method);
    }
    final globals = frozen
        ? unit
        : parseFile(
            File(
              '${root.path}/packages/foresight_core/lib/src/graph_labels.dart',
            ),
          );
    for (final node in globals.declarations) {
      if (node is ClassDeclaration && !identical(node, owner)) {
        add(node.namePart.typeName.lexeme, node);
      } else if (node is FunctionDeclaration) {
        add(node.name.lexeme, node);
      } else if (node is TopLevelVariableDeclaration) {
        for (final variable in node.variables.variables) {
          add(variable.name.lexeme, node);
        }
      }
    }
    final run = symbols[frozen ? 'run' : '_migrateTo'];
    if (run is! MethodDeclaration || run.body is! BlockFunctionBody) {
      reject('missing migration switch');
    }
    final statements = (run.body as BlockFunctionBody).block.statements;
    if (statements.length != 1 || statements.single is! SwitchStatement) {
      reject('migration dispatcher must contain only its switch');
    }
    final branch = statements.single as SwitchStatement;
    if (branch.expression.toSource() != 'version') {
      reject('unexpected migration switch selector');
    }
    final entries = <int, Map<String, Object?>>{};
    final versions = <int>{};
    for (var i = 0; i < branch.members.length; i++) {
      final member = branch.members[i];
      if (member is SwitchDefault) continue;
      if (member is! SwitchPatternCase ||
          member.guardedPattern.whenClause != null) {
        reject('unsupported migration case');
      }
      final version = int.tryParse(member.guardedPattern.pattern.toSource());
      if (version == null || version < 1 || !versions.add(version)) {
        reject('invalid/duplicate migration version');
      }
      SwitchMember body = member;
      var next = i + 1;
      while (body.statements.isEmpty && next < branch.members.length) {
        body = branch.members[next++];
      }
      if (body.statements.isEmpty || body is SwitchDefault) {
        reject('empty migration $version');
      }
      final closureNames = migrationClosures[version];
      if (closureNames == null) {
        // An old reviewed-main checker protects its known prefix while allowing
        // an append. The newly reviewed checker inventories new closures.
        continue;
      }
      final closure = <String, List<String>>{};
      for (final name in closureNames.toList()..sort()) {
        final definition = symbols[name];
        if (definition == null) {
          reject('missing migration-private definition $name');
        }
        closure[name] = canonicalTokens(definition, frozen: frozen);
      }
      final canonical = jsonEncode({
        'body': [
          for (final statement in body.statements)
            ...canonicalTokens(statement, frozen: frozen),
        ],
        'closure': closure,
      });
      entries[version] = {
        'sha256': digest(utf8.encode(canonical)),
        'symbols': closure.keys.toList(),
      };
    }
    if (versions.isEmpty || versions.any((n) => n > versions.length)) {
      reject('migration versions must form a contiguous prefix');
    }
    return MigrationSource(entries, frozen, versions.length);
  }
}

void _verifyIsolation(CompilationUnit unit, ClassDeclaration owner) {
  const imports = {'dart:convert', 'package:sqlite3/sqlite3.dart'};
  final seen = <String>{};
  for (final directive in unit.directives) {
    if (directive is! ImportDirective ||
        directive.prefix != null ||
        directive.combinators.isNotEmpty ||
        directive.deferredKeyword != null ||
        directive.configurations.isNotEmpty ||
        !imports.contains(directive.uri.stringValue)) {
      reject('frozen module imports must be only dart:convert and sqlite3');
    }
    seen.add(directive.uri.stringValue!);
  }
  if (seen.length != imports.length) {
    reject('missing frozen module primitive imports');
  }
  if (owner.extendsClause != null ||
      owner.withClause != null ||
      owner.implementsClause != null) {
    reject('frozen migrations cannot inherit live behavior');
  }
  final fields = owner.body.members.whereType<FieldDeclaration>().toList();
  if (fields.length != 1 ||
      canonicalTokens(fields.single).join(' ') != 'final Database db ;') {
    reject('frozen migrations require only their final Database primitive');
  }
  final constructors = owner.body.members
      .whereType<ConstructorDeclaration>()
      .toList();
  if (constructors.length != 1 ||
      canonicalTokens(constructors.single).join(' ') !=
          'ApplicationMigrations ( this . db ) ;') {
    reject('frozen migration construction cannot execute behavior');
  }
  for (final declaration
      in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
    if (!declaration.variables.isConst) {
      reject('frozen globals must be constants');
    }
  }
  // New private helpers may be appended, but cannot shadow imported primitives
  // (jsonDecode, DateTime, Database) or the frozen global constructor/allocator.
  for (final method in owner.body.members.whereType<MethodDeclaration>()) {
    final name = method.name.lexeme;
    if ((!name.startsWith('_') && name != 'run' && name != 'rows') ||
        historicalBindings.containsKey(name) && name != '_documentLabels') {
      reject('method can redirect an imported/global frozen binding: $name');
    }
  }
  const allowedGlobals = {
    'ApplicationMigrations',
    '_HistoricalDocumentLabel',
    '_historicalAllocateGraphLabelColor',
    '_historicalGraphLabelPalette',
  };
  for (final declaration in unit.declarations) {
    final names = switch (declaration) {
      ClassDeclaration node => [node.namePart.typeName.lexeme],
      FunctionDeclaration node => [node.name.lexeme],
      TopLevelVariableDeclaration node => [
        for (final variable in node.variables.variables) variable.name.lexeme,
      ],
      _ => <String>[],
    };
    if (names.isEmpty || names.any((name) => !allowedGlobals.contains(name))) {
      reject('frozen globals cannot shadow SQLite/SDK bindings');
    }
  }
  for (final alias in historicalBindings.keys) {
    final text = canonicalTokens(unit).join(' ');
    if (!text.contains(alias)) {
      reject('missing isolated historical binding $alias');
    }
  }
}

Map<String, Object?> fixtureDigests(Directory root) {
  final directory = Directory('${root.path}/$fixturePath');
  if (!directory.existsSync()) {
    reject('missing checksummed historical fixtures');
  }
  final files = directory.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final file in files)
      file.uri.pathSegments.last: digest(file.readAsBytesSync()),
  };
}

Map<String, Object?> _readManifest(Directory root) {
  final file = File('${root.path}/$manifestPath');
  if (!file.existsSync()) {
    reject(
      'trusted manifest missing; explicit first-introduction bootstrap is required',
    );
  }
  final result = jsonDecode(file.readAsStringSync());
  if (result is! Map<String, dynamic> ||
      result['schema'] != 1 ||
      result['canonical_format'] != 'dart-token-v1') {
    reject('unsupported manifest format');
  }
  return result;
}

void _same(Object? actual, Object? expected, String what) {
  if (jsonEncode(actual) != jsonEncode(expected)) {
    reject('$what differs from independently supplied reviewed main');
  }
}

Map<String, Object?> verifyMigrations({
  required Directory candidate,
  required Directory trusted,
  required String trustedCommit,
  Directory? bootstrapRoot,
  String? bootstrapCommit,
  bool bootstrap = false,
  bool createManifest = false,
}) {
  if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(trustedCommit)) {
    reject('record an independently resolved full reviewed-main SHA');
  }
  if ((bootstrapRoot == null) != (bootstrapCommit == null) ||
      bootstrapCommit != null &&
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(bootstrapCommit)) {
    reject(
      'bootstrap origin requires its independently exported root and full SHA',
    );
  }
  if (!bootstrap && bootstrapRoot != null) {
    reject(
      'existing main manifest cannot be rebaselined through bootstrap origin',
    );
  }
  final baselineManifestExists = File(
    '${trusted.path}/$manifestPath',
  ).existsSync();
  if (bootstrap && baselineManifestExists) {
    reject('bootstrap cannot replace an existing main manifest');
  }
  if (!bootstrap && !baselineManifestExists) {
    reject('main manifest missing; no implicit bootstrap fallback');
  }
  final current = MigrationSource.read(candidate, requireFrozen: true);
  final expected = MigrationSource.read(trusted, requireFrozen: !bootstrap);
  final origin = bootstrapRoot ?? trusted;
  final originCommit = bootstrapCommit ?? trustedCommit;
  if (bootstrapRoot != null) {
    // The caller must independently prove originCommit is an ancestor of the
    // actual main HEAD. Exports have no .git; neither this input nor candidate
    // manifest metadata substitutes for that workflow-owned ancestry proof.
    final original = MigrationSource.read(origin, requireFrozen: false);
    if (original.frozen || original.versionCount != expected.versionCount) {
      reject(
        'reviewed main migration set changed since bootstrap origin; refresh/rebase',
      );
    }
    for (final entry in original.entries.entries) {
      _same(
        expected.entries[entry.key],
        entry.value,
        'current-main migration ${entry.key} body and closure since bootstrap origin',
      );
    }
  }
  if (bootstrap && (expected.frozen || expected.entries.length != 15)) {
    reject(
      'first-introduction source must be the reviewed shipped schema15 baseline',
    );
  }
  if (current.versionCount < expected.versionCount) {
    reject('candidate removed historical migrations');
  }
  for (final entry in expected.entries.entries) {
    _same(current.entries[entry.key], entry.value, 'migration ${entry.key}');
  }
  final fixtures = fixtureDigests(candidate);
  if (bootstrap) {
    for (final file in ['store.dart', 'graph_labels.dart']) {
      final expectedBytes = File(
        '${origin.path}/packages/foresight_core/lib/src/$file',
      ).readAsBytesSync();
      _same(
        fixtures['$file.txt'],
        digest(expectedBytes),
        'historical fixture $file',
      );
    }
  } else {
    final baseline = _readManifest(trusted);
    for (final entry in (baseline['migrations'] as Map).entries) {
      final version = int.parse(entry.key as String);
      _same(
        expected.entries[version],
        entry.value,
        'trusted manifest migration $version',
      );
    }
    for (final entry in (baseline['fixtures'] as Map).entries) {
      _same(fixtures[entry.key], entry.value, 'frozen fixture ${entry.key}');
    }
  }
  final manifest = <String, Object?>{
    'schema': 1,
    'canonical_format': 'dart-token-v1',
    'bootstrap_source_commit': bootstrap
        ? originCommit
        : _readManifest(trusted)['bootstrap_source_commit'],
    'migrations': {
      for (final entry in current.entries.entries) '${entry.key}': entry.value,
    },
    'fixtures': fixtures,
    'binding_map': historicalBindings,
    'locations': {
      'registry': '$migrationPath:ApplicationMigrations.run',
      'historical_owner': 'packages/foresight_core/lib/src/store.dart:Store',
      'historical_graph': 'packages/foresight_core/lib/src/graph_labels.dart',
    },
  };
  if (createManifest) {
    if (current.entries.length != current.versionCount) {
      reject(
        'new migrations require a reviewed explicit closure inventory before manifest generation',
      );
    }
    File('${candidate.path}/$manifestPath').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    );
  } else {
    final committed = _readManifest(candidate);
    final committedEntries = committed['migrations'] as Map;
    if (committedEntries.length != current.versionCount) {
      reject('committed manifest must enumerate every candidate version');
    }
    for (final entry in current.entries.entries) {
      _same(
        committedEntries['${entry.key}'],
        entry.value,
        'committed migration ${entry.key}',
      );
    }
    for (final key in [
      'schema',
      'canonical_format',
      'bootstrap_source_commit',
      'fixtures',
      'binding_map',
      'locations',
    ]) {
      _same(committed[key], manifest[key], 'committed manifest $key');
    }
  }
  return {
    'mode': bootstrap ? 'verified-source-bootstrap' : 'reviewed-main-prefix',
    'trusted_commit': trustedCommit,
    'checked_versions': expected.entries.length,
    'candidate_versions': current.versionCount,
    'fixtures': fixtures.length,
  };
}

void main(List<String> args) {
  try {
    if (args.isEmpty || !['check', 'create-manifest'].contains(args.first)) {
      reject(
        'usage: migration_guard.dart check|create-manifest --candidate-root PATH --trusted-root PATH --trusted-commit SHA [--bootstrap [--bootstrap-root PATH --bootstrap-commit SHA]]',
      );
    }
    final options = <String, String>{};
    var bootstrap = false;
    for (var index = 1; index < args.length; index++) {
      final argument = args[index];
      if (argument == '--bootstrap') {
        bootstrap = true;
        continue;
      }
      if (![
            '--candidate-root',
            '--trusted-root',
            '--trusted-commit',
            '--bootstrap-root',
            '--bootstrap-commit',
          ].contains(argument) ||
          ++index == args.length ||
          options.containsKey(argument)) {
        reject('invalid or duplicate option $argument');
      }
      options[argument] = args[index];
    }
    if (![
      '--candidate-root',
      '--trusted-root',
      '--trusted-commit',
    ].every(options.containsKey)) {
      reject(
        'candidate root, independently supplied trusted root and full SHA are required',
      );
    }
    final result = verifyMigrations(
      candidate: Directory(options['--candidate-root']!),
      trusted: Directory(options['--trusted-root']!),
      trustedCommit: options['--trusted-commit']!,
      bootstrapRoot: options['--bootstrap-root'] == null
          ? null
          : Directory(options['--bootstrap-root']!),
      bootstrapCommit: options['--bootstrap-commit'],
      bootstrap: bootstrap,
      createManifest: args.first == 'create-manifest',
    );
    stdout.writeln(jsonEncode(result));
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
