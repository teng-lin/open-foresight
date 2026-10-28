import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:foresight_core/src/application_services/installed_audio_media.dart';
import 'package:foresight_core/src/platform_services.dart';
import 'package:foresight_test_support/test_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File worker, receipt, provenance;
  late Map<String, Object?> value;
  late RuntimeConfiguration configuration;
  final mac = Platform.isMacOS, system = DynamicLibrary.process();
  final chmod = system
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  void mode(String path, int selected) {
    final n = path.toNativeUtf8();
    try {
      expect(chmod(n, selected), 0);
    } finally {
      calloc.free(n);
    }
  }

  Future<void> rejected() => expectLater(
    loadInstalledAudioMediaExecutable(configuration),
    throwsA(anything),
  );
  void save() => receipt.writeAsStringSync(jsonEncode(value));
  setUp(() {
    root = createTestTempDirectorySync('installed-media-');
    final payload = mac ? '${root.path}/Contents/Resources' : root.path;
    worker = File('$payload/bin/foresight-media-worker');
    worker.parent.createSync(recursive: true);
    final binary = Uint8List(4096)
      ..setAll(
        0,
        mac
            ? [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]
            : [0x7f, 0x45, 0x4c, 0x46, 2, 1],
      );
    if (!mac) binary[18] = 0x3e;
    worker.writeAsBytesSync(binary);
    mode(worker.path, 0x1ed);
    provenance = File('$payload/licenses/media/media-worker-build.json');
    provenance.parent.createSync(recursive: true);
    provenance.writeAsStringSync(
      jsonEncode({
        'protocol': 1,
        'platform': mac ? 'Darwin' : 'Linux',
        'architecture': mac ? 'arm64' : 'x86_64',
        'build_id': 'b' * 64,
        'description': {
          'protocol': 1,
          'bootstrap_protocol': 2,
          'supervisor_fence_protocol': 1,
          'build_id': 'b' * 64,
          'capability_transport': 'scm_rights',
          'owner_lock_fd': 7,
          'operations': [
            'encode-opus',
            'encode-recording-wav-v1',
            'decode-pcm',
            'mix-export-mp3',
          ],
        },
      }),
    );
    receipt = File(
      mac
          ? '$payload/media-worker.json'
          : '$payload/share/open-foresight/media-worker.json',
    );
    receipt.parent.createSync(recursive: true);
    value = {
      'schema': 1,
      'kind': 'audio-media-worker',
      'target': mac ? 'darwin-arm64' : 'linux-x86_64',
      'path': 'bin/foresight-media-worker',
      'protocol': 1,
      'bootstrap_protocol': 2,
      'supervisor_fence_protocol': 1,
      'build_id': 'b' * 64,
      'sha256': sha256.convert(binary).toString(),
      'bytes': binary.length,
      'macos_cdhash': mac ? 'c' * 40 : null,
      'capabilities': {
        'operations': [
          'encode-opus',
          'encode-recording-wav-v1',
          'decode-pcm',
          'mix-export-mp3',
        ],
        'assembly_protocol': 0,
      },
      'source_receipt_sha256': sha256
          .convert(provenance.readAsBytesSync())
          .toString(),
    };
    save();
    configuration = RuntimeConfiguration({'FORESIGHT_INSTALL_ROOT': root.path});
    // Small private fixture files are retained when a check fails.
  });
  test(
    'complete fixed installed receipt returns a physical executable capability',
    () async {
      final result = await loadInstalledAudioMediaExecutable(configuration);
      expect(result.path, worker.path);
      expect(result.sha256, value['sha256']);
      expect(result.buildId, 'b' * 64);
      expect(result.macosCdHash, mac ? 'c' * 40 : '');
    },
  );
  test(
    'installation metadata keeps the current worker assembly-disabled',
    () async {
      final installed = await loadInstalledAudioMediaInstallation(
        configuration,
      );
      expect(installed.assemblyProtocol, 0);
      expect(installed.operations, hasLength(4));
      expect(
        () => installed.operations.add('assemble-mp3-v1'),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'forged assembly capability cannot authorize an older four-op receipt',
    () async {
      value['capabilities'] = {
        'assembly_protocol': 1,
        'operations': [
          'encode-opus',
          'encode-recording-wav-v1',
          'decode-pcm',
          'mix-export-mp3',
          'assemble-mp3-v1',
          'assemble-opus-v1',
          'assemble-pcm-v1',
        ],
      };
      save();
      await rejected();
    },
  );
  test('missing installation root refuses worker and PATH overrides', () async {
    configuration = RuntimeConfiguration({
      'FORESIGHT_MEDIA_WORKER': worker.path,
      'PATH': worker.parent.path,
    });
    await rejected();
  });
  test(
    'normalizes lexical components from sealed installation config',
    () async {
      configuration = RuntimeConfiguration({
        'FORESIGHT_INSTALL_ROOT': '${root.path}/Contents/../.',
      });
      expect(
        (await loadInstalledAudioMediaExecutable(configuration)).path,
        worker.path,
      );
    },
  );
  for (final mutation in [
    'missing',
    'sha',
    'size',
    'unknown',
    'target',
    'path',
    'protocol',
    'build',
    'source',
    'cdhash',
  ]) {
    test('rejects $mutation receipt before executable admission', () async {
      switch (mutation) {
        case 'missing':
          receipt.deleteSync();
          break;
        case 'sha':
          value['sha256'] = 'a' * 64;
          save();
          break;
        case 'size':
          value['bytes'] = 4095;
          save();
          break;
        case 'unknown':
          value['executable'] = worker.path;
          save();
          break;
        case 'target':
          value['target'] = 'foreign';
          save();
          break;
        case 'path':
          value['path'] = '../bin/foresight-media-worker';
          save();
          break;
        case 'protocol':
          value['supervisor_fence_protocol'] = 0;
          save();
          break;
        case 'build':
          value['build_id'] = 'd' * 64;
          save();
          break;
        case 'source':
          provenance.writeAsStringSync('{}');
          break;
        case 'cdhash':
          value['macos_cdhash'] = mac ? 'invalid' : 'c' * 40;
          save();
          break;
      }
      await rejected();
    });
  }
  String selected(String name) => switch (name) {
    'worker' => worker.path,
    'receipt' => receipt.path,
    'provenance' => provenance.path,
    'bin' => worker.parent.path,
    _ => root.path,
  };
  for (final name in ['worker', 'receipt', 'provenance', 'bin', 'root']) {
    test('rejects symlink $name', () async {
      final path = selected(name), moved = '${selected(name)}-original';
      if (FileSystemEntity.isDirectorySync(path)) {
        Directory(path).renameSync(moved);
      } else {
        File(path).renameSync(moved);
      }
      Link(path).createSync(moved);
      await rejected();
    });
    test('rejects writable $name', () async {
      mode(selected(name), 0x1ff);
      await rejected();
    });
  }
  test('rejects non-executable worker', () async {
    mode(worker.path, 0x1a4);
    await rejected();
  });
  test('rejects foreign executable header even with updated SHA', () async {
    final bytes = worker.readAsBytesSync();
    bytes[4] = 0;
    worker.writeAsBytesSync(bytes);
    value['sha256'] = sha256.convert(bytes).toString();
    save();
    await rejected();
  });
  test('bounds receipt and executable reads before allocation', () async {
    receipt.writeAsStringSync('x' * 16385);
    await rejected();
    save();
    final file = worker.openSync(mode: FileMode.write);
    file.truncateSync(32 * 1024 * 1024 + 1);
    file.closeSync();
    await rejected();
  });
  test('rejects hard-linked executable', () async {
    final link = system
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('link');
    final old = worker.path.toNativeUtf8(),
        other = '${worker.path}-link'.toNativeUtf8();
    try {
      expect(link(old, other), 0);
    } finally {
      calloc.free(old);
      calloc.free(other);
    }
    await rejected();
  });
  test('rejects FIFO without blocking', () async {
    worker.deleteSync();
    final fifo = system
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Uint32),
          int Function(Pointer<Utf8>, int)
        >('mkfifo');
    final name = worker.path.toNativeUtf8();
    try {
      expect(fifo(name, 0x180), 0);
    } finally {
      calloc.free(name);
    }
    await rejected().timeout(const Duration(seconds: 2));
  });
  test('rejects symlink ancestor above installation root', () async {
    final alias = p.join(root.parent.path, 'alias-${p.basename(root.path)}');
    Link(alias).createSync(root.path);
    configuration = RuntimeConfiguration({
      'FORESIGHT_INSTALL_ROOT': '$alias/Contents/..',
    });
    await rejected();
  });
}
