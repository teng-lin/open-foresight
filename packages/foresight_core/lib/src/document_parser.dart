import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'agent_access.dart';
import 'platform_services.dart';

class Parser {
  final bool _macOS;
  final String? _macParser;
  final RuntimeConfiguration? _configuration;
  final Duration extractionTimeout;
  final Future<Process> Function(String, List<String>) _startProcess;
  Parser({
    bool? macOS,
    String? macParser,
    this.extractionTimeout = const Duration(seconds: 30),
    Future<Process> Function(String, List<String>)? startProcess,
    RuntimeConfiguration? configuration,
  }) : _macOS = macOS ?? Platform.isMacOS,
       _macParser = macParser,
       _configuration = configuration?.snapshot(),
       _startProcess =
           startProcess ??
           ((executable, arguments) => Process.start(
             executable,
             arguments,
             includeParentEnvironment: false,
             environment: {'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8'},
           ));

  Future<ProcessResult> _extractProcess(
    String executable,
    List<String> arguments,
  ) async {
    if (!executable.startsWith('/')) {
      throw StateError('Extractor must use an absolute path');
    }
    final process = await _startProcess(executable, arguments);
    var expired = false;
    final timer = Timer(extractionTimeout, () {
      expired = true;
      process.kill(ProcessSignal.sigkill);
    });
    Future<String> bounded(Stream<List<int>> stream) async {
      final bytes = <int>[];
      await for (final chunk in stream) {
        if (bytes.length + chunk.length > ImportPolicy.maxFileBytes) {
          process.kill(ProcessSignal.sigkill);
          throw StateError('Extracted document exceeds the 10 MiB limit');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes, allowMalformed: true);
    }

    try {
      final output = await Future.wait([
        bounded(process.stdout),
        bounded(process.stderr),
      ]);
      final code = await process.exitCode;
      if (expired) {
        throw TimeoutException(
          'Document extraction timed out',
          extractionTimeout,
        );
      }
      return ProcessResult(process.pid, code, output[0], output[1]);
    } finally {
      timer.cancel();
    }
  }

  Future<(String, String)> extract(String path) async {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file ||
        File(path).lengthSync() > ImportPolicy.maxFileBytes) {
      throw StateError('Import requires a regular file no larger than 10 MiB');
    }
    final lower = path.toLowerCase();
    if (_macOS && (lower.endsWith('.pdf') || lower.endsWith('.rtf'))) {
      return _MacDocumentExtractor(
        _extractProcess,
        _macParser ?? runtimeSnapshot(_configuration)['FORESIGHT_FILE_PARSER'],
      ).extract(path, lower);
    }
    if (lower.endsWith('.pdf')) {
      final r = await _LinuxDocumentExtractor(
        _extractProcess,
      ).extract('pdftotext', path, ['-layout']);
      if (r.exitCode != 0) {
        throw StateError('PDF extraction failed: ${r.stderr}');
      }
      return (r.stdout as String, 'pdftotext -layout (Linux adapter)');
    }
    if (lower.endsWith('.rtf')) {
      final r = await _LinuxDocumentExtractor(
        _extractProcess,
      ).extract('unrtf', path, ['--text', '--quiet']);
      if (r.exitCode != 0) {
        throw StateError('RTF extraction failed: ${r.stderr}');
      }
      // unrtf 0.21 emits this separator even when --quiet hides its metadata.
      var text = r.stdout as String;
      final banner = RegExp(
        r'^-----------------\r?$',
        multiLine: true,
      ).firstMatch(text);
      if (banner != null) {
        final prefix = text.substring(0, banner.start);
        if (prefix.trim().isEmpty ||
            prefix.trimLeft().startsWith('### Translation from RTF')) {
          text = text.substring(banner.end).trimLeft();
        }
      }
      return (text, 'unrtf --text (Linux adapter)');
    }
    final bytes = <int>[];
    await for (final chunk in File(
      path,
    ).openRead().timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > ImportPolicy.maxFileBytes) {
        throw StateError('File exceeds the 10 MiB import limit');
      }
      bytes.addAll(chunk);
    }
    return (utf8.decode(bytes, allowMalformed: true), 'UTF-8 text');
  }
}

typedef _ExtractProcess =
    Future<ProcessResult> Function(String executable, List<String> arguments);

final class _LinuxDocumentExtractor {
  final _ExtractProcess _extractProcess;
  const _LinuxDocumentExtractor(this._extractProcess);
  Future<ProcessResult> extract(
    String tool,
    String path,
    List<String> options,
  ) async {
    final file = File(path).resolveSymbolicLinksSync();
    final isolated = '/input/document${tool == 'pdftotext' ? '.pdf' : '.rtf'}';
    // A fresh user/PID/network/mount namespace exposes only system runtime
    // libraries and the one selected input. Profile files and credentials are
    // absent. Failure to establish the sandbox fails the import closed.
    ProcessResult result;
    try {
      result = await _extractProcess('/usr/bin/bwrap', [
        '--unshare-all',
        '--die-with-parent',
        '--new-session',
        '--cap-drop',
        'ALL',
        '--ro-bind',
        '/usr',
        '/usr',
        '--ro-bind-try',
        '/lib',
        '/lib',
        '--ro-bind-try',
        '/lib64',
        '/lib64',
        '--ro-bind-try',
        '/etc/fonts',
        '/etc/fonts',
        '--proc',
        '/proc',
        '--dev',
        '/dev',
        '--tmpfs',
        '/tmp',
        '--dir',
        '/input',
        '--ro-bind',
        file,
        isolated,
        '--chdir',
        '/input',
        '--clearenv',
        '--setenv',
        'HOME',
        '/tmp',
        '--setenv',
        'PATH',
        '/nonexistent',
        '--',
        '/usr/bin/$tool',
        ...options,
        isolated,
        if (tool == 'pdftotext') '-',
      ]);
    } on ProcessException catch (error) {
      final dependency = tool == 'pdftotext' ? 'poppler-utils' : 'unrtf';
      throw StateError(
        'Cannot start the document sandbox at /usr/bin/bwrap. '
        'Install the Linux import dependencies (bubblewrap and $dependency) '
        'and check executable permissions: '
        '${error.message}',
      );
    }
    final diagnostic = result.stderr.toString().trim();
    final namespaceFailure =
        diagnostic.startsWith('bwrap:') &&
        !RegExp(r'^bwrap:\s*exec\w*\b').hasMatch(diagnostic) &&
        RegExp(
          r'namespace|unshare|userns|[ug]id map|capset|^bwrap:\s*loopback:',
          caseSensitive: false,
        ).hasMatch(diagnostic);
    if (result.exitCode != 0 && namespaceFailure) {
      throw StateError(
        'The document sandbox could not start. Check the bubblewrap installation '
        'and host user-namespace permissions. On Ubuntu 24.04, an administrator '
        'may need to allow bubblewrap user namespaces in its AppArmor profile. '
        '$diagnostic',
      );
    }
    return result;
  }
}

final class _MacDocumentExtractor {
  final _ExtractProcess _extractProcess;
  final String? _macParser;
  const _MacDocumentExtractor(this._extractProcess, this._macParser);
  Future<(String, String)> extract(String path, String lower) async {
    final executable = _macParser;
    if (executable == null || executable.isEmpty) {
      throw StateError(
        'The bundled PDF/RTF extractor is unavailable. Reinstall Open Foresight.',
      );
    }
    ProcessResult result;
    try {
      result = await _extractProcess(executable, [
        lower.endsWith('.pdf') ? '--pdf' : '--rtf',
        path,
      ]);
    } on ProcessException catch (error) {
      throw StateError(
        'Cannot launch the bundled file extractor. Reinstall Open Foresight: ${error.message}',
      );
    }
    if (result.exitCode != 0) {
      throw StateError(
        'File extraction failed: ${result.stderr.toString().trim()}',
      );
    }
    final text = result.stdout as String;
    if (text.trim().isEmpty) {
      throw StateError('The selected document contains no extractable text.');
    }
    return (
      text,
      lower.endsWith('.pdf')
          ? 'PDFKit (macOS adapter)'
          : 'NSAttributedString RTF (macOS adapter)',
    );
  }
}
