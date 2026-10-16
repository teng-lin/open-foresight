import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'platform_services.dart';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'reference_tools.dart';
import 'reference_tool_parser.dart';

/// Packaged installations always use their bundled native worker, including
/// profiles that still contain the former Python runner path.
String liteRtRunner(String registered) =>
    runtimeConfiguration['FORESIGHT_LITERT_RUNNER'] ?? registered;

typedef CreateNative = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef CreateDart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);

Future<int> probeNativeModel(
  String libraryPath,
  String runtime,
  String model, {
  String backend = 'llama_cpp',
}) => Isolate.run(() => _createAndProbe(libraryPath, runtime, model, backend));
int _createAndProbe(String path, String runtime, String model, String backend) {
  final lib = DynamicLibrary.open(path);
  final a = runtime.toNativeUtf8(), b = model.toNativeUtf8();
  Pointer<Void> engine = nullptr;
  try {
    if (backend == 'llama_cpp') {
      engine = lib.lookupFunction<CreateNative, CreateDart>('fs_engine_create')(
        a,
        b,
      );
    } else if (backend == 'litert_lm') {
      engine = lib
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('fs_engine_create_backend')(a, b, 1);
    } else {
      throw ArgumentError.value(backend, 'backend');
    }
    if (engine == nullptr)
      throw StateError('Native model initialization failed');
    final rc = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fs_engine_probe')(engine);
    if (rc != 0) {
      var detail = '';
      final state = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('fs_engine_state')(engine);
      if (state != nullptr) {
        try {
          detail =
              (jsonDecode(state.toDartString()) as Map)['error']?.toString() ??
              '';
        } finally {
          lib.lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('fs_string_free')(state);
        }
      }
      throw StateError(
        'Native model load/inference probe failed ($rc)${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    return engine.address;
  } catch (_) {
    if (engine != nullptr)
      lib.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fs_engine_destroy')(engine);
    rethrow;
  } finally {
    calloc.free(a);
    calloc.free(b);
  }
}

class _GenerationRequest {
  final String id;
  final Pointer<Void> handle;
  final int epoch;
  bool released = false;
  bool cancelled = false;
  _GenerationRequest(this.id, this.handle, this.epoch);
}

class NativeRuntime {
  late final DynamicLibrary lib;
  Pointer<Void> engine = nullptr, conversation = nullptr;
  String template = 'raw';
  final String libraryPath;
  int _epoch = 0;
  _GenerationRequest? _active;
  bool get generating => _active != null;
  bool get loaded => engine != nullptr && conversation != nullptr;
  String _phase = 'unconfigured', _lastError = '';
  NativeRuntime(String path) : libraryPath = path {
    lib = DynamicLibrary.open(path);
  }
  Map<String, dynamic> get effectiveState {
    if (engine == nullptr) return {'state': _phase, 'error': _lastError};
    final p = lib
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('fs_engine_state')(engine);
    if (p == nullptr) return {'state': 'failed'};
    try {
      return jsonDecode(p.toDartString()) as Map<String, dynamic>;
    } finally {
      lib.lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('fs_string_free')(p);
    }
  }

  Future<void> load(
    String runtime,
    String model, {
    String backend = 'llama_cpp',
  }) async {
    if (backend == 'litert_lm') runtime = liteRtRunner(runtime);
    if (!['llama_cpp', 'litert_lm'].contains(backend))
      throw ArgumentError.value(backend);
    close();
    final epoch = _epoch;
    _phase = 'loading';
    _lastError = '';
    template = backend == 'llama_cpp' && model.toLowerCase().contains('qwen')
        ? 'chatml'
        : 'raw';
    try {
      final address = await probeNativeModel(
        libraryPath,
        runtime,
        model,
        backend: backend,
      );
      final loaded = Pointer<Void>.fromAddress(address);
      if (epoch != _epoch) {
        lib.lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fs_engine_destroy')(loaded);
        throw StateError('Model load cancelled before adoption');
      }
      engine = loaded;
      conversation = lib
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)
          >('fs_conversation_create')(engine);
      if (conversation == nullptr) {
        close();
        throw StateError('Native conversation initialization failed');
      }
      _phase = 'ready';
    } catch (e) {
      if (epoch == _epoch) {
        _phase = 'failed';
        _lastError = e.toString();
      }
      rethrow;
    }
  }

  Stream<Map<String, dynamic>> generate(
    String id,
    String prompt, {
    String systemPrompt =
        'Follow the requested task faithfully. Do not invent facts.',
    Map<String, dynamic>? responseSchema,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) => _generate(
    id,
    prompt,
    systemPrompt: systemPrompt,
    responseSchema: responseSchema,
    timeout: timeout,
    maxOutputTokens: maxOutputTokens,
  );

  Stream<Map<String, dynamic>> generateWithTools(
    String id,
    String prompt, {
    required List<Map<String, dynamic>> tools,
    required ReferenceToolDispatcher dispatcher,
    List<Map<String, dynamic>> messages = const [],
    String systemPrompt =
        'Follow the requested task faithfully. Do not invent facts.',
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) => _generate(
    id,
    prompt,
    tools: tools,
    toolDispatcher: dispatcher,
    initialMessages: messages,
    systemPrompt: systemPrompt,
    timeout: timeout,
    maxOutputTokens: maxOutputTokens,
  );

  Stream<Map<String, dynamic>> _generate(
    String id,
    String prompt, {
    String systemPrompt =
        'Follow the requested task faithfully. Do not invent facts.',
    Map<String, dynamic>? responseSchema,
    List<Map<String, dynamic>>? tools,
    ReferenceToolDispatcher? toolDispatcher,
    List<Map<String, dynamic>> initialMessages = const [],
    Duration timeout = const Duration(minutes: 5),
    int maxOutputTokens = 256,
  }) async* {
    if (engine == nullptr || conversation == nullptr) {
      throw StateError('Generation model unavailable');
    }
    if (_active != null) throw StateError('Generation already in progress');
    if ((tools == null) != (toolDispatcher == null) ||
        (tools != null && (tools.isEmpty || responseSchema != null))) {
      throw ArgumentError('Tools require a dispatcher and no response schema');
    }
    if (id.isEmpty ||
        timeout <= Duration.zero ||
        maxOutputTokens < 1 ||
        maxOutputTokens > 3072) {
      throw ArgumentError('A request ID and positive timeout are required');
    }
    // Each request owns a conversation. Destroy joins the native worker, so
    // the done-event/active-flag race cannot leak into the next generation.
    final handle = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('fs_conversation_create')(engine);
    if (handle == nullptr) throw StateError('Native conversation unavailable');
    final owner = _GenerationRequest(id, handle, _epoch);
    _active = owner;
    final clock = Stopwatch()..start();
    try {
      // Tool conversations carry a distinct native system message below.
      if (tools == null) {
        if (template == 'chatml') {
          prompt =
              '<|im_start|>system\n$systemPrompt<|im_end|>\n'
              '<|im_start|>user\n$prompt<|im_end|>\n<|im_start|>assistant\n';
        } else {
          prompt = '$systemPrompt\n\n$prompt';
        }
      }
      final a = id.toNativeUtf8(), b = prompt.toNativeUtf8();
      final schema = tools != null
          ? jsonEncode({
              'tools': tools,
              'system_message': systemPrompt,
              'delegate_tool_detection': true,
              'messages': initialMessages,
            }).toNativeUtf8()
          : responseSchema == null
          ? nullptr.cast<Utf8>()
          : jsonEncode(responseSchema).toNativeUtf8();
      late int rc;
      try {
        if (tools != null) {
          rc = lib
              .lookupFunction<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Int32,
                ),
                int Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  int,
                )
              >('fs_generate_tools')(handle, a, b, schema, maxOutputTokens);
        } else if (maxOutputTokens != 256) {
          rc = lib
              .lookupFunction<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Int32,
                ),
                int Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  int,
                )
              >('fs_generate_options')(handle, a, b, schema, maxOutputTokens);
        } else if (responseSchema != null) {
          rc = lib
              .lookupFunction<
                Int32 Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                ),
                int Function(
                  Pointer<Void>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                  Pointer<Utf8>,
                )
              >('fs_generate_json')(handle, a, b, schema);
        } else {
          rc = lib
              .lookupFunction<
                Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
                int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
              >('fs_generate')(handle, a, b);
        }
      } finally {
        calloc.free(a);
        calloc.free(b);
        if (schema != nullptr) calloc.free(schema);
      }
      if (rc != 0) throw StateError('Native generation start failed ($rc)');
      final poll = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Int32),
            Pointer<Utf8> Function(Pointer<Void>, int)
          >('fs_event_poll');
      final free = lib
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('fs_string_free');
      var modelTurns = 0;
      while (true) {
        // close/load may have destroyed this handle while awaiting the timer
        // or while a consumer was processing a yielded event.
        if (owner.released || owner.epoch != _epoch) {
          throw StateError('Generation closed before completion');
        }
        if (clock.elapsed >= timeout) {
          throw TimeoutException('Native generation timed out', timeout);
        }
        final p = poll(handle, 0);
        if (p == nullptr) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          continue;
        }
        late Map<String, dynamic> event;
        try {
          event = jsonDecode(p.toDartString()) as Map<String, dynamic>;
        } finally {
          free(p);
        }
        if (event['request_id'] != id) {
          throw StateError('Native generation returned a different request ID');
        }
        if (event['type'] == 'tool_request' ||
            event['type'] == 'model_response') {
          if (toolDispatcher == null)
            throw StateError('Unexpected tool request');
          final delegated = event['type'] == 'model_response';
          final payload = jsonDecode(event['text'] as String);
          final calls = delegated
              ? extractReferenceToolCalls(payload as Map<String, dynamic>)
              : payload as List<dynamic>;
          if (delegated) modelTurns++;
          late Map<String, dynamic> message;
          if (delegated && (calls == null || calls.isEmpty)) {
            message = {'finish': true};
          } else if (delegated && modelTurns >= 20) {
            message = {
              'finish': true,
              'error': 'Max turns reached after tool call detection',
            };
          } else {
            final interrupted = Completer<Map<String, dynamic>>();
            final monitor = Timer.periodic(const Duration(milliseconds: 20), (
              _,
            ) {
              if (interrupted.isCompleted) return;
              if (owner.released || owner.epoch != _epoch || owner.cancelled) {
                interrupted.completeError(
                  StateError('Tool request is no longer current'),
                );
              } else if (clock.elapsed >= timeout) {
                interrupted.completeError(
                  TimeoutException('Native generation timed out', timeout),
                );
              }
            });
            try {
              final reply = await Future.any([
                toolDispatcher.handle(calls!, maxTokens: 4096),
                interrupted.future,
              ]);
              message = delegated ? {'message': reply} : reply;
            } finally {
              monitor.cancel();
            }
          }
          if (owner.released || owner.epoch != _epoch || owner.cancelled) {
            throw StateError('Tool request is no longer current');
          }
          if (clock.elapsed >= timeout)
            throw TimeoutException('Native generation timed out', timeout);
          final request = id.toNativeUtf8();
          final reply = jsonEncode(message).toNativeUtf8();
          try {
            final result = lib
                .lookupFunction<
                  Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
                  int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
                >('fs_generation_tool_reply')(handle, request, reply);
            if (result != 0)
              throw StateError(
                'Tool request was cancelled or already answered',
              );
          } finally {
            calloc.free(request);
            calloc.free(reply);
          }
          continue;
        }
        if (event['type'] == 'tool_answer') {
          final response =
              jsonDecode(event['text'] as String) as Map<String, dynamic>;
          if (response['error'] != null)
            throw StateError(response['error'].toString());
          final content = response['content'];
          final String text;
          if (content is String) {
            text = content;
          } else if (content is List) {
            text = content
                .where((part) => part is Map && part['type'] == 'text')
                .map((part) => part['text'] as String)
                .join();
          } else {
            throw FormatException('Invalid tool answer content');
          }
          yield {...event, 'type': 'delta', 'text': text, 'response': response};
          continue;
        }
        yield event;
        if (event['type'] == 'done') break;
      }
    } finally {
      _release(owner);
      if (identical(_active, owner)) _active = null;
    }
  }

  void _release(_GenerationRequest owner) {
    if (owner.released) return;
    owner.released = true;
    lib.lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)
    >('fs_conversation_destroy')(owner.handle, 1);
  }

  /// Supplying an ID prevents a stale UI/controller from cancelling a new task.
  bool cancel({String? requestId}) {
    final owner = _active;
    if (owner == null ||
        owner.released ||
        (requestId != null && owner.id != requestId))
      return false;
    owner.cancelled = true;
    lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('fs_generation_cancel')(owner.handle);
    return true;
  }

  void close() {
    _epoch++;
    _phase = 'unconfigured';
    final owner = _active;
    if (owner != null) _release(owner);
    _active = null;
    if (conversation != nullptr) {
      lib.lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('fs_conversation_destroy')(conversation, 1);
      conversation = nullptr;
    }
    if (engine != nullptr) {
      lib.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('fs_engine_destroy')(engine);
      engine = nullptr;
    }
  }
}
