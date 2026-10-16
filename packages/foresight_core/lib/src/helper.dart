import 'platform_services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'generated/rag_service.pbgrpc.dart';
import 'generated/helper_control.pbgrpc.dart' as control;

class Helper {
  final String socket, storage;
  late final ClientChannel channel;
  late final RagServiceClient client;
  Process? process;
  bool stopping = false;
  bool shutdownVerified = true;
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
            : 'sentence-transformers-cpu';
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

  Future<void> start() async {
    final executable = runtimeConfiguration['FORESIGHT_HELPER'];
    if (manageProcess && executable != null && process == null) {
      bool live = false;
      try {
        await client.ping(
          PingRequest(),
          options: CallOptions(timeout: const Duration(milliseconds: 400)),
        );
        live = true;
      } catch (_) {}
      if (!live) {
        process = await Process.start(executable, [
          socket,
          storage,
        ], environment: runtimeConfiguration.environment);
        process!.stdout.drain<void>();
        process!.stderr.drain<void>();
        process!.exitCode.then((code) async {
          process = null;
          state = 'helper exited ($code)';
          snapshot = null;
          changed?.call();
          if (!stopping && restarts++ < 3) {
            await Future<void>.delayed(Duration(seconds: restarts));
            try {
              await start();
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
      state = 'live (compatibility ${ping.version})';
      await watch?.cancel();
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

  Future<void> close() async {
    stopping = true;
    await watch?.cancel();
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
        final pid = int.tryParse(snapshot?.instanceId.split('-').first ?? '');
        if (pid != null) {
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
              if (matches(pid, a, b, identity) == 1) {
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
