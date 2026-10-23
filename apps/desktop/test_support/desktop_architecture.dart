import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Shared shell adapters and pure presentation libraries outside feature roots.
const sharedDesktopLibraries = {
  'app_theme.dart',
  'commands.dart',
  'desktop_environment.dart',
  'desktop_visuals.dart',
  'failure_text.dart',
  'feature_request_identity.dart',
  'generated_content.dart',
  'service_edit_dialog.dart',
};

List<String> desktopArchitectureViolations(String relative, String source) {
  final unit = parseString(content: source, path: relative).unit;
  final violations = <String>[];
  final ownFeature = relative.startsWith('features/')
      ? relative.split('/')[1]
      : null;
  for (final part in unit.directives.whereType<PartOfDirective>()) {
    final target = part.uri?.stringValue;
    if (ownFeature == null ||
        target == null ||
        !Uri(path: relative)
            .resolve(target)
            .normalizePath()
            .path
            .startsWith('features/$ownFeature/')) {
      violations.add('$relative: application part of $target');
    }
  }
  for (final directive in unit.directives.whereType<UriBasedDirective>()) {
    final uri = directive.uri.stringValue ?? '';
    final core = uri.startsWith('package:foresight_core/');
    if (core &&
        uri != 'package:foresight_core/desktop.dart' &&
        !(relative == 'main.dart' &&
            uri == 'package:foresight_core/desktop_bootstrap.dart')) {
      violations.add('$relative: implementation dependency $uri');
    }
    if (uri.startsWith('package:mcp_dart/')) {
      violations.add('$relative: MCP dependency $uri');
    }
    if (directive is PartOfDirective ||
        (directive is PartDirective && uri.endsWith('main.dart'))) {
      violations.add('$relative: application part $uri');
    }
    if (directive is PartDirective) {
      final target = Uri(path: relative).resolve(uri).normalizePath().path;
      if (ownFeature == null || !target.startsWith('features/$ownFeature/')) {
        violations.add('$relative: part crosses feature ownership $target');
      }
    }
    if (ownFeature == null ||
        core ||
        uri.startsWith('dart:') ||
        (uri.startsWith('package:') &&
            !uri.startsWith('package:open_foresight/')))
      continue;
    final target = uri.startsWith('package:open_foresight/')
        ? uri.substring('package:open_foresight/'.length)
        : Uri(path: relative).resolve(uri).normalizePath().path;
    final allowed =
        target.startsWith('features/$ownFeature/') ||
        (target.startsWith('features/') && target.endsWith('/ports.dart')) ||
        target.startsWith('presentation/') ||
        target == 'shell/ports.dart' ||
        target == 'shell/workspace_tab.dart' ||
        sharedDesktopLibraries.contains(target);
    if (!allowed)
      violations.add('$relative: feature ownership dependency $target');
  }
  for (final alias in unit.declarations.whereType<TypeAlias>()) {
    if (RegExp(r'\bReadQuery\b').hasMatch(alias.toSource())) {
      violations.add('$relative: ReadQuery constructor alias');
    }
  }
  const forbidden = {
    'Store',
    'SqliteStoreReader',
    'Domain',
    'Application',
    'NativeRuntime',
    'ServiceClient',
    'Helper',
    'GoogleClient',
  };
  var token = unit.beginToken;
  while (!token.isEof) {
    if (token.lexeme == 'ReadQuery') {
      var following = token.next;
      if (following?.lexeme == '<') {
        var depth = 0;
        do {
          final lexeme = following!.lexeme;
          if (lexeme == '<') depth++;
          if (RegExp(r'^>+$').hasMatch(lexeme)) depth -= lexeme.length;
          following = following.next;
        } while (following != null && !following.isEof && depth > 0);
      }
      if (following?.lexeme == '(' || following?.lexeme == '.') {
        violations.add('$relative: ReadQuery construction or tear-off');
      }
    }
    if (forbidden.contains(token.lexeme)) {
      violations.add(
        '$relative: write/transport/query-construction type ${token.lexeme}',
      );
    }
    if (ownFeature != null &&
        {
          'Workspace',
          '_WorkspaceState',
          'WorkspaceTestAccess',
        }.contains(token.lexeme)) {
      violations.add('$relative: shell-state back-reference ${token.lexeme}');
    }
    token = token.next!;
  }
  return violations;
}

List<File> desktopDartFiles(Directory desktop) => desktop
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .toList();

List<String> desktopSizeViolations(String relative, String source) {
  final violations = <String>[];
  final lines =
      '\n'.allMatches(source).length + (source.endsWith('\n') ? 0 : 1);
  if (lines >= 800 || (relative == 'main.dart' && lines >= 300)) {
    violations.add('$relative: $lines lines');
  }
  final visitor = _WidgetSizes(relative, source, violations);
  parseString(content: source, path: relative).unit.accept(visitor);
  return violations;
}

class _WidgetSizes extends RecursiveAstVisitor<void> {
  _WidgetSizes(this.path, this.source, this.violations);
  final String path, source;
  final List<String> violations;
  void check(AstNode node, String name, TypeAnnotation? type) {
    if (name != 'build' && !(type?.toSource().contains('Widget') ?? false))
      return;
    final lines =
        '\n'.allMatches(source.substring(node.offset, node.end)).length + 1;
    if (lines >= 150) violations.add('$path: $name has $lines lines');
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    check(node, node.name.lexeme, node.returnType);
    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    check(node, node.name.lexeme, node.returnType);
    super.visitFunctionDeclaration(node);
  }
}
