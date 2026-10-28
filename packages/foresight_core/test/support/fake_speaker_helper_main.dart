// A real child process that speaks the observer protocol. Scenarios:
//   ok          orderly helper
//   hang        ignores stdin close, `stop` and SIGTERM after starting
//   crash_once  exits abruptly after its first observation, once per state file
//   garbage     writes a non-protocol line after starting
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final options = <String, String>{
    for (final arg in args)
      if (arg.startsWith('--') && arg.contains('='))
        arg.substring(2, arg.indexOf('=')): arg.substring(arg.indexOf('=') + 1),
  };
  final scenario = options['scenario'] ?? 'ok';
  File(
    options['pidfile']!,
  ).writeAsStringSync('$pid\n', mode: FileMode.append, flush: true);
  if (scenario == 'hang') ProcessSignal.sigterm.watch().listen((_) {});

  var seq = 0;
  void send(String type, [Map<String, Object?> fields = const {}]) {
    stdout.writeln(jsonEncode({'v': 1, 'type': type, 'seq': seq++, ...fields}));
  }

  int nowMs() => DateTime.now().microsecondsSinceEpoch ~/ 1000;
  send('hello', {
    'helper': 'fake_helper',
    'helper_version': '1.0.0',
    'parser_version': 'fake-1',
    'platform': Platform.isMacOS ? 'macos' : 'linux',
  });

  Timer? ticker;
  String? session;
  void observe() => send('observation', {
    'session': session,
    'read_start_ms': nowMs(),
    'read_end_ms': nowMs(),
    'target': {'pid': pid, 'window': 'w1'},
    'complete': true,
    'parser_version': 'fake-1',
    'participants': [
      {'ref': 'p1', 'name': 'Ada Lovelace', 'self': false},
    ],
    'speakers': [
      {'ref': 'p1', 'method': 'participant_status'},
    ],
  });

  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          final request = jsonDecode(line) as Map<String, dynamic>;
          final id = request['id'];
          switch (request['type']) {
            case 'capabilities' || 'setup':
              send('capabilities', {'id': id, 'state': 'available'});
            case 'clock':
              send('clock', {'id': id, 'monotonic_ms': nowMs()});
            case 'start':
              session = request['session'] as String;
              send('started', {
                'id': id,
                'session': session,
                'target': {'pid': pid, 'window': 'w1'},
              });
              if (scenario == 'garbage') {
                stdout.writeln('not a frame');
                return;
              }
              final period = Duration(milliseconds: request['poll_ms'] as int);
              ticker = Timer.periodic(period, (_) => observe());
              if (scenario == 'crash_once') {
                final marker = File(options['statefile']!);
                if (!marker.existsSync()) {
                  marker.writeAsStringSync('crashed');
                  Timer(const Duration(milliseconds: 120), () => exit(3));
                }
              }
            case 'stop':
              if (scenario == 'hang') return;
              ticker?.cancel();
              send('stopped', {'id': id, 'session': session});
              exit(0);
          }
        },
        onDone: () {
          if (scenario != 'hang') exit(0);
        },
      );
  if (scenario == 'hang') Timer.periodic(const Duration(seconds: 1), (_) {});
}
