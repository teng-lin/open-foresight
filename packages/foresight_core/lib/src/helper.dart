import 'platform_services.dart';
import 'version.dart';
import 'helper_channel.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:grpc/service_api.dart' as grpc_api;
import 'generated/rag_service.pbgrpc.dart';
import 'generated/helper_control.pbgrpc.dart' as control;

/// The helper currently stores one local account; preserve this wire identity.
const helperUserId = 'local_user';

void validateHelperCompatibility(
  PingResponse ping,
  control.State value, {
  RuntimeConfiguration? configuration,
}) {
  final config = configuration ?? runtimeConfiguration;
  if (!ping.success ||
      ping.version != '1.0.3' ||
      value.referenceVersion != '1.0.3') {
    throw StateError(
      'Incompatible helper protocol; stop the previous service before restarting',
    );
  }
  final revision = config['FORESIGHT_RUNTIME_REVISION'];
  final prefix = 'open-foresight-$openForesightVersion-';
  final build = value.buildId;
  final builtRevision = build.startsWith(prefix)
      ? build.substring(prefix.length)
      : '';
  if (!RegExp(r'^[0-9a-f]{7,40}$').hasMatch(builtRevision) ||
      (revision != null &&
          revision.isNotEmpty &&
          !revision.startsWith(builtRevision))) {
    throw StateError(
      'Helper build $build differs from this application; stop the previous service before restarting',
    );
  }
}

/// Bound crash loops without permanently exhausting recovery for a long-lived service.
class HelperRestartBudget {
  final DateTime Function() now;
  final Duration window;
  int attempts = 0;
  DateTime? _began;
  HelperRestartBudget({
    DateTime Function()? now,
    this.window = const Duration(minutes: 10),
  }) : now = now ?? DateTime.now;
  bool reserve() {
    final time = now();
    if (_began == null ||
        time.difference(_began!) >= window ||
        time.isBefore(_began!)) {
      attempts = 0;
      _began = time;
    }
    if (attempts >= 3) return false;
    attempts++;
    return true;
  }

  void reset() {
    attempts = 0;
    _began = null;
  }
}

/// A gRPC channel to the helper listening at [socket].
HelperChannel helperChannel(String socket) => HelperChannel(
  InternetAddress(socket, type: InternetAddressType.unix),
  port: 0,
  options: const ChannelOptions(
    credentials: ChannelCredentials.insecure(),
    connectTimeout: Duration(seconds: 3),
  ),
);

/// The helper's RAG client over [channel], with its request timeout.
RagServiceClient helperClient(grpc_api.ClientChannel channel) =>
    RagServiceClient(
      channel,
      options: CallOptions(timeout: const Duration(seconds: 45)),
    );

enum AdoptedIdentity { notAdopted, gone, matches, unknown }

class Helper {
  final String socket, storage;
  late final grpc_api.ClientChannel channel;
  late final RagServiceClient client;
  Process? process;
  Future<Process>? _launching;
  Future<PingResponse>? _startupProbe;
  Future<void>? _closing;
  bool stopping = false;
  bool incompatible = false;
  bool shutdownVerified = true;
  bool _adopted = false;
  bool get adopted => _adopted;
  bool _probing = false, _launchingNow = false;
  bool get starting => _probing || _launchingNow;
  final Duration startupProbeTimeout;
  final HelperRestartBudget restartBudget = HelperRestartBudget();
  int get restarts => restartBudget.attempts;
  set restarts(int value) {
    restartBudget.attempts = value;
  }

  String state = 'disconnected';
  control.State? snapshot;
  StreamSubscription<control.State>? watch;
  void Function()? changed;
  Future<void> Function()? onReady;
  final bool manageProcess;
  Helper(
    this.socket,
    this.storage, {
    this.manageProcess = true,
    this.startupProbeTimeout = const Duration(milliseconds: 400),
  }) {
    channel = helperChannel(socket);
    client = helperClient(channel);
  }
  Future<bool> hasActiveModel(String path, String digest, bool useGpu) async {
    if (!path.endsWith('.litertlm')) return false;
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
            : 'litert-lm-embedding-cpu';
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
    if (incompatible) {
      throw StateError(
        'Restart the application service to replace the incompatible helper',
      );
    }
    if (!manageProcess) return;
    restartBudget.reset();
    if (process == null || snapshot == null) await start();
  }

  Future<void>? _starting;
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);
  Future<void> _start() async {
    if (incompatible) {
      throw StateError(
        'Restart the application service to replace the incompatible helper',
      );
    }
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
      _probing = true;
      try {
        existing = await (_startupProbe = client.ping(
          PingRequest(),
          options: CallOptions(timeout: startupProbeTimeout),
        ));
      } catch (_) {
      } finally {
        _probing = false;
      }
      if (stopping) return;
      if (existing != null) {
        _adopted = true;
        // A failed lookup is a transport failure, not proof of an incompatible
        // build. Keep that channel retryable; only reject a validated mismatch.
        snapshot = await control.HelperControlClient(channel).getState(
          control.Empty(),
          options: CallOptions(timeout: const Duration(seconds: 3)),
        );
        try {
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
        _launchingNow = true;
        try {
          process = await (_launching = Process.start(executable, [
            socket,
            storage,
          ], environment: runtimeConfiguration.environment));
        } finally {
          _launchingNow = false;
        }
        unawaited(
          process!.stdout.drain<void>().catchError((Object error) {
            stderr.writeln('Helper stdout drain: $error');
          }),
        );
        unawaited(
          process!.stderr.drain<void>().catchError((Object error) {
            stderr.writeln('Helper stderr drain: $error');
          }),
        );
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
        unawaited(
          process!.exitCode
              .then((code) async {
                process = null;
                state = 'helper exited ($code)';
                snapshot = null;
                changed?.call();
                if (!stopping && restartBudget.reserve()) {
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
              })
              .catchError((Object error) {
                stderr.writeln('Helper exit handling: $error');
              }),
        );
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

  Future<AdoptedIdentity> verifyAdoptedIdentity() async {
    if (!_adopted && snapshot == null) return AdoptedIdentity.notAdopted;
    final instance = snapshot?.instanceId ?? '';
    if (!RegExp(r'^[1-9][0-9]*-[1-9][0-9]*$').hasMatch(instance)) {
      return AdoptedIdentity.unknown;
    }
    try {
      final library = DynamicLibrary.open(runtimeConfiguration.nativeLibrary);
      final matches = library
          .lookupFunction<
            Int32 Function(Int64, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
            int Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
          >('fs_process_matches');
      final a = socket.toNativeUtf8(),
          b = storage.toNativeUtf8(),
          identity = instance.toNativeUtf8();
      try {
        return switch (matches(
          int.parse(instance.split('-').first),
          a,
          b,
          identity,
        )) {
          0 => AdoptedIdentity.gone,
          1 => AdoptedIdentity.matches,
          _ => AdoptedIdentity.unknown,
        };
      } finally {
        calloc.free(a);
        calloc.free(b);
        calloc.free(identity);
      }
    } catch (_) {
      return AdoptedIdentity.unknown;
    }
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
        final identity = await verifyAdoptedIdentity();
        if (identity == AdoptedIdentity.gone) {
          shutdownVerified = true;
        } else if (identity == AdoptedIdentity.unknown) {
          stderr.writeln(
            'Could not verify adopted helper ownership; leaving it running',
          );
        } else if (identity == AdoptedIdentity.matches) {
          final pid = int.parse(snapshot!.instanceId.split('-').first);
          Process.killPid(pid, ProcessSignal.sigterm);
          for (var attempt = 0; attempt < 50; attempt++) {
            if (await verifyAdoptedIdentity() == AdoptedIdentity.gone) {
              shutdownVerified = true;
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
      }
    }
    // The peer may already have exited; abort remaining HTTP/2 calls so
    // transport draining cannot keep an otherwise stopped service alive.
    await channel.terminate();
  }
}
