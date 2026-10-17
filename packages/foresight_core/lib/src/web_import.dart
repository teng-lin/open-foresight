import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:charset/charset.dart' show Charset;
import 'package:enough_convert/enough_convert.dart' show Big5Codec, GbkCodec;
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

const maxWebPageBytes = 5 * 1024 * 1024;

/// Reject special-use networks, including mapped IPv4 and cloud metadata.
/// IPv6 is limited to global unicast, excluding transition/documentation space.
bool isGlobalWebAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4 &&
      address.type != InternetAddressType.IPv6) {
    return false;
  }
  final bytes = address.rawAddress;
  if (bytes.length == 16) {
    if (bytes.take(10).every((n) => n == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return isGlobalWebAddress(
        InternetAddress.fromRawAddress(Uint8List.fromList(bytes.sublist(12))),
      );
    }
    if (bytes[0] & 0xe0 != 0x20) return false;
    if (bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        (bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8))) {
      return false;
    }
    if (bytes[0] == 0x20 && bytes[1] == 0x02) return false;
    if (bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0) {
      return false;
    }
    return true;
  }
  if (bytes.length != 4) return false;
  final a = bytes[0], b = bytes[1], c = bytes[2], d = bytes[3];
  return !(a == 0 ||
      a == 10 ||
      a == 127 ||
      a >= 224 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 &&
          (b == 168 ||
              (b == 0 && (c == 0 || c == 2)) ||
              (b == 88 && c == 99))) ||
      (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
      (a == 203 && b == 0 && c == 113) ||
      (a == 168 && b == 63 && c == 129 && d == 16));
}

Uri webImportUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw StateError(
      'Enter an HTTP or HTTPS URL without embedded credentials.',
    );
  }
  return uri.removeFragment();
}

Uri webImportRedirect(Uri from, String location) {
  final next = webImportUri(from.resolve(location).toString());
  if (from.scheme == 'https' && next.scheme != 'https') {
    throw StateError('HTTPS redirects cannot downgrade to HTTP.');
  }
  return next;
}

/// Bounded downloads connect directly to a previously validated DNS result.
/// Each redirect gets its own lookup, client and pinned socket. TLS still checks
/// the URL hostname; proxy environment settings cannot bypass the address check.
class WebPageImporter {
  WebPageImporter({
    Future<List<InternetAddress>> Function(String)? lookup,
    Future<ConnectionTask<Socket>> Function(InternetAddress, int)? connect,
    this.timeout = const Duration(seconds: 30),
    this.parserTimeout = const Duration(seconds: 3),
    this.securityContext,
  }) : _lookup = lookup ?? InternetAddress.lookup,
       _connect = connect ?? Socket.startConnect;

  final Future<List<InternetAddress>> Function(String) _lookup;
  final Future<ConnectionTask<Socket>> Function(InternetAddress, int) _connect;
  final Duration timeout, parserTimeout;
  final SecurityContext? securityContext;

  Future<String> fetch(
    Uri initial, {
    bool allowPrivateNetwork = false,
    bool Function()? current,
  }) async {
    HttpClient? active;
    final elapsed = Stopwatch()..start();
    var stopped = false;
    void checkCurrent() {
      if (stopped || (current != null && !current())) {
        throw StateError('Operation cancelled');
      }
    }

    Future<String> download() async {
      var uri = webImportUri(initial.toString());
      for (var hop = 0; hop <= 5; hop++) {
        checkCurrent();
        final literal = InternetAddress.tryParse(uri.host);
        final addresses = literal == null ? await _lookup(uri.host) : [literal];
        checkCurrent();
        if (addresses.isEmpty ||
            (!allowPrivateNetwork &&
                addresses.any((address) => !isGlobalWebAddress(address)))) {
          throw StateError(
            'URL targets a private or special-use network. Enable private network access explicitly to import it.',
          );
        }
        final client = HttpClient(context: securityContext)
          ..connectionTimeout = timeout
          ..findProxy = (_) => 'DIRECT';
        active = client;
        client.connectionFactory = (target, proxyHost, proxyPort) async {
          checkCurrent();
          ConnectionTask<Socket>? pending;
          Socket? socket;
          var cancelled = false;
          Future<Socket> establish() async {
            for (var i = 0; i < addresses.length; i++) {
              checkCurrent();
              if (cancelled) throw StateError('Operation cancelled');
              try {
                pending = await _connect(addresses[i], target.port);
                if (cancelled || stopped) pending!.cancel();
                final raw = await pending!.socket;
                socket = raw;
                if (cancelled || stopped) {
                  raw.destroy();
                  throw StateError('Operation cancelled');
                }
                if (target.scheme == 'https') {
                  socket = await SecureSocket.secure(
                    raw,
                    host: target.host,
                    context: securityContext,
                  );
                }
                if (cancelled || stopped) {
                  socket!.destroy();
                  throw StateError('Operation cancelled');
                }
                return socket!;
              } on SocketException {
                if (cancelled || stopped || i == addresses.length - 1) rethrow;
              }
            }
            throw StateError('No reachable URL address.');
          }

          final connected = establish();
          return ConnectionTask.fromSocket(connected, () {
            cancelled = true;
            pending?.cancel();
            socket?.destroy();
          });
        };
        try {
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          final response = await request.close();
          checkCurrent();
          if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
            final location = response.headers.value(HttpHeaders.locationHeader);
            if (location == null || hop == 5) {
              throw StateError('URL has too many or invalid redirects.');
            }
            uri = webImportRedirect(uri, location);
            continue;
          }
          if (response.statusCode != 200) {
            throw StateError('URL returned HTTP ${response.statusCode}');
          }
          final type = response.headers.contentType;
          if (type == null || !type.mimeType.startsWith('text/')) {
            throw StateError(
              'URL must contain HTML or plain text. Add binary documents as files.',
            );
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response) {
            checkCurrent();
            if (bytes.length + chunk.length > maxWebPageBytes) {
              throw StateError('Page exceeds 5 MB.');
            }
            bytes.add(chunk);
          }
          checkCurrent();
          final remaining = timeout - elapsed.elapsed;
          if (remaining <= Duration.zero) {
            throw StateError('URL import exceeded its time limit.');
          }
          final text = await parseWebPage(
            bytes.takeBytes(),
            mimeType: type.mimeType,
            charset: type.charset,
            timeout: remaining < parserTimeout ? remaining : parserTimeout,
          );
          checkCurrent();
          return text;
        } finally {
          client.close(force: true);
          if (identical(active, client)) active = null;
        }
      }
      throw StateError('URL has too many redirects.');
    }

    try {
      return await download().timeout(
        timeout,
        onTimeout: () {
          stopped = true;
          active?.close(force: true);
          throw StateError('URL import exceeded its time limit.');
        },
      );
    } finally {
      stopped = true;
      active?.close(force: true);
    }
  }
}

/// Decode and parse in a disposable isolate. A deadline kills CPU-bound parsers,
/// so malformed HTML cannot occupy the service isolate or outlive its request.
Future<String> parseWebPage(
  Uint8List bytes, {
  required String mimeType,
  String? charset,
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (bytes.length > maxWebPageBytes) throw StateError('Page exceeds 5 MB.');
  final port = ReceivePort(), errors = ReceivePort();
  final result = Completer<String>();
  Isolate? worker;
  final timer = Timer(timeout, () {
    worker?.kill(priority: Isolate.immediate);
    if (!result.isCompleted) {
      result.completeError(StateError('Page parsing exceeded its time limit.'));
    }
  });
  final messages = port.listen((message) {
    if (result.isCompleted) return;
    final value = message as List;
    if (value[0] == true) {
      result.complete(value[1] as String);
    } else {
      result.completeError(StateError(value[1] as String));
    }
  });
  final failures = errors.listen((message) {
    if (!result.isCompleted) {
      result.completeError(StateError('Unable to parse page: $message'));
    }
  });
  unawaited(
    Isolate.spawn(_parseWebPage, [
      port.sendPort,
      TransferableTypedData.fromList([bytes]),
      mimeType,
      charset,
    ], onError: errors.sendPort).then(
      (isolate) {
        worker = isolate;
        if (result.isCompleted) isolate.kill(priority: Isolate.immediate);
      },
      onError: (Object error) {
        if (!result.isCompleted) result.completeError(error);
      },
    ),
  );
  try {
    return await result.future;
  } finally {
    timer.cancel();
    worker?.kill(priority: Isolate.immediate);
    await messages.cancel();
    await failures.cancel();
    port.close();
    errors.close();
  }
}

void _parseWebPage(List<Object?> request) {
  final port = request[0] as SendPort;
  try {
    final bytes = (request[1] as TransferableTypedData)
        .materialize()
        .asUint8List();
    final charset = ((request[3] as String?) ?? 'utf-8').trim().toLowerCase();
    final Encoding? encoding;
    if (['big5', 'big-5', 'cn-big5', 'csbig5'].contains(charset)) {
      encoding = const Big5Codec();
    } else if (['gbk', 'gb2312', 'gb_2312-80', 'x-gbk'].contains(charset)) {
      encoding = const GbkCodec();
    } else {
      encoding = Charset.getByName(charset);
    }
    if (encoding == null) {
      throw StateError('Unsupported response charset: $charset');
    }
    final decoded = encoding.decode(bytes);
    String text;
    if (request[2] == 'text/html') {
      // Bound parser work/memory before building the DOM; counting is linear.
      if ('<'.allMatches(decoded).length > 100000) {
        throw StateError('Page has too much HTML markup.');
      }
      final document = html.parse(decoded);
      final output = StringBuffer();
      final pending = <Node?>[...?document.body?.nodes.reversed];
      while (pending.isNotEmpty) {
        final node = pending.removeLast();
        if (node == null) {
          output.write(' ');
          continue;
        }
        if (node is Element) {
          if ([
            'script',
            'style',
            'noscript',
            'template',
            'head',
          ].contains(node.localName)) {
            continue;
          }
          output.write(' ');
          pending.add(null);
          pending.addAll(node.nodes.reversed);
        } else if (node is Text) {
          output.write(node.data);
        }
      }
      text = output.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    } else {
      text = decoded.trim();
    }
    if (text.isEmpty) throw StateError('No readable text found.');
    port.send([true, text]);
  } catch (error) {
    port.send([false, error.toString()]);
  }
}
