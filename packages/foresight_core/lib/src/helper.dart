import 'platform_services.dart';
import 'version.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'generated/rag_service.pbgrpc.dart';
import 'generated/helper_control.pbgrpc.dart' as control;

void validateHelperCompatibility(
  PingResponse ping,
  control.State value, {
  RuntimeConfiguration? configuration,
}) {
  final config = configuration ?? runtimeConfiguration;
  if (!ping.success ||
      ping.version != '1.0.3' ||
      value.referenceVersion != '1.0.3')
    throw StateError(
      'Incompatible helper protocol; stop the previous service before restarting',
    );
  final revision = config['FORESIGHT_RUNTIME_REVISION'];
  final prefix = 'open-foresight-$openForesightVersion-';
  final build = value.buildId;
  final builtRevision = build.startsWith(prefix)
      ? build.substring(prefix.length)
      : '';
  if (!RegExp(r'^[0-9a-f]{7,40}$').hasMatch(builtRevision) ||
      (revision != null &&
          revision.isNotEmpty &&
          !revision.startsWith(builtRevision)))
    throw StateError(
      'Helper build $build differs from this application; stop the previous service before restarting',
    );
}

class Helper {
  final String socket, storage;
  late final ClientChannel channel;
  late final RagServiceClient client;
  Process? process;
  Future<Process>? _launching;
  Future<PingResponse>? _startupProbe;
  Future<void>? _closing;
  bool stopping = false;
  bool incompatible = false;
  bool shutdownVerified = true;
  bool _adopted = false;
  int restarts = 0;
  String state = 'disconnected';
  control.State? snapshot;
  StreamSubscription<control.State>? watch;
  void Function()? changed;
  Future<void> Function()? onReady;
  final bool manageProcess;
  Helper(this.socket, this.storage, {this.manageProcess = true}) {
    channel = ClientChannel(
      InternetAddress(socket, type: InternetAddressType.unix),
      port: 0,
      options: const ChannelOptions(
        credentials: ChannelCredentials.insecure(),
        connectTimeout: Duration(seconds: 3),
      ),
    );
    client = RagServiceClient(
      channel,
      options: CallOptions(timeout: const Duration(seconds: 45)),
    );
  }
  Future<bool> hasActiveModel(String path, String digest, bool useGpu) async {
    final deadline = DateTime.now().add(const Duration(minutes: 30));
    try {
      while (!stopping) {
        final current = await control.HelperControlClient(channel).getState(
          control.Empty(),
          options: CallOptions(timeout: const Duration(seconds: 3)),
        );
        // An earlier frontend may have disconnected while the helper was
        // rebuilding. Wait for that transaction instead of queueing another.
        if (current.pipeline == 'loading' &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        final backend = useGpu
            ? 'litert-lm-embedding-gpu'
            : path.endsWith('.litertlm')
            ? 'litert-lm-embedding-cpu'
            : 'onnx-bert-cpu';
        return current.pipeline == 'ready' &&
            current.tokenizerReady &&
            current.lastError.isEmpty &&
            current.model.path == path &&
            current.model.modelDigest == digest &&
            current.model.backend == backend;
      }
    } on GrpcError {
      // Older or unavailable control services still use normal configuration.
    }
    return false;
  }

  Future<void>? _recovering;

  /// Explicit recovery starts a new bounded restart cycle after a degraded
  /// helper exhausted automatic retries. Healthy processes are kept in place.
  Future<void> recover() =>
      _recovering ??= _recover().whenComplete(() => _recovering = null);
  Future<void> _recover() async {
    if (stopping) throw StateError('Helper is closing');
    if (incompatible)
      throw StateError(
        'Restart the application service to replace the incompatible helper',
      );
    if (!manageProcess) return;
    restarts = 0;
    if (process == null || snapshot == null) await start();
  }

  Future<void>? _starting;
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);
  Future<void> _start() async {
    if (incompatible)
      throw StateError(
        'Restart the application service to replace the incompatible helper',
      );
    final executable = runtimeConfiguration['FORESIGHT_HELPER'];
    if (manageProcess && executable != null && process == null) {
      if (_launching != null) {
        try {
          await _launching;
        } catch (_) {}
        if (process != null || stopping) return;
      }
      bool live = false;
      PingResponse? existing;
      try {
        existing = await (_startupProbe = client.ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(milliseconds: 400)),
        ));
      } catch (_) {}
      if (stopping) return;
      if (existing != null) {
        _adopted = true;
        try {
          snapshot = await control.HelperControlClient(channel).getState(
            control.Empty(),
            options: CallOptions(timeout: const Duration(seconds: 3)),
          );
          validateHelperCompatibility(existing, snapshot!);
        } catch (error) {
          incompatible = true;
          state = 'incompatible helper: $error';
          changed?.call();
          // The service can keep storage-only RPCs available after startup
          // failure; none of those calls may reuse this incompatible transport.
          await channel.terminate();
          rethrow;
        }
        live = true;
      }
      if (!live) {
        process = await (_launching = Process.start(executable, [
          socket,
          storage,
        ], environment: runtimeConfiguration.environment));
        process!.stdout.drain<void>();
        process!.stderr.drain<void>();
        if (stopping) {
          final late = process!;
          late.kill();
          try {
            await late.exitCode.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            late.kill(ProcessSignal.sigkill);
            await late.exitCode;
          }
          process = null;
          return;
        }
        process!.exitCode.then((code) async {
          process = null;
          state = 'helper exited ($code)';
          snapshot = null;
          changed?.call();
          if (!stopping && restarts++ < 3) {
            await Future<void>.delayed(Duration(seconds: restarts));
            try {
              final starting = _starting;
              if (starting != null) await starting;
              if (!stopping && process == null) await start();
            } catch (e) {
              state = 'app restore failed: $e';
              changed?.call();
            }
          }
        });
      }
    }
    for (var n = 0; n < 20; n++) {
      if (stopping) return;
      PingResponse ping;
      try {
        ping = await client.ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(seconds: 1)),
        );
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        continue;
      }
      if (stopping) return;
      state = 'live (compatibility ${ping.version})';
      await watch?.cancel();
      if (stopping) return;
      watch = control.HelperControlClient(channel)
          .watchState(control.WatchRequest())
          .listen(
            (s) {
              snapshot = s;
              changed?.call();
            },
            onError: (Object e) {
              state = 'state stream unavailable: $e';
              changed?.call();
            },
          );
      changed?.call();
      await onReady?.call();
      changed?.call();
      return;
    }
    state = 'unavailable';
    changed?.call();
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    stopping = true;
    await watch?.cancel();
    // Resolve launch/adoption races before deciding which process is owned.
    try {
      if (_startupProbe != null) await _startupProbe;
    } catch (_) {
      /* No helper answered. */
    }
    try {
      if (_launching != null) await _launching;
    } catch (_) {
      /* The helper could not start. */
    }
    if (manageProcess) {
      final owned = process;
      if (owned != null) {
        owned.kill();
        try {
          await owned.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          owned.kill(ProcessSignal.sigkill);
          await owned.exitCode;
        }
      } else {
        // A service restart can adopt its predecessor's surviving helper.
        // Verify the private profile arguments before releasing that owner.
        if (_adopted || snapshot != null) shutdownVerified = false;
        final instance = snapshot?.instanceId ?? '';
        final pid = int.tryParse(instance.split('-').first);
        if (pid != null &&
            pid > 0 &&
            RegExp(r'^[1-9][0-9]*-[1-9][0-9]*$').hasMatch(instance)) {
          shutdownVerified = false;
          try {
            final library = DynamicLibrary.open(
              runtimeConfiguration.nativeLibrary,
            );
            final matches = library
                .lookupFunction<
                  Int32 Function(
                    Int64,
                    Pointer<Utf8>,
                    Pointer<Utf8>,
                    Pointer<Utf8>,
                  ),
                  int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
                >('fs_process_matches');
            final a = socket.toNativeUtf8(), b = storage.toNativeUtf8();
            final identity = snapshot!.instanceId.toNativeUtf8();
            try {
              final match = matches(pid, a, b, identity);
              if (match == 0) {
                // The adopted identity is positively gone or replaced. Never
                // signal a mismatching PID; unknown inspection remains unsafe.
                shutdownVerified = true;
              } else if (match == 1) {
                Process.killPid(pid, ProcessSignal.sigterm);
                for (var attempt = 0; attempt < 50; attempt++) {
                  if (matches(pid, a, b, identity) == 0) {
                    shutdownVerified = true;
                    break;
                  }
                  await Future<void>.delayed(const Duration(milliseconds: 100));
                }
              }
            } finally {
              calloc.free(a);
              calloc.free(b);
              calloc.free(identity);
            }
          } catch (error) {
            stderr.writeln(
              'Could not verify adopted helper ownership; leaving it running: $error',
            );
          }
        }
      }
    }
    // The peer may already have exited; abort remaining HTTP/2 calls so
    // transport draining cannot keep an otherwise stopped service alive.
    await channel.terminate();
  }
}
