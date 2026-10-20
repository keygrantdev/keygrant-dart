// The default HTTP adapter against a real server on the loopback interface
// (adapters.test.ts `fetchHttp`; URLSessionHTTPTests.swift): JSON in and out,
// every status answered, and every call bounded and aborted at its bound.
// No Flutter test binding here: it would stand in for every HttpClient.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

const _bound = Duration(seconds: 5);

/// What the server received.
typedef _Received = ({String method, String path, String? contentType, String body});

/// A server on 127.0.0.1 that answers each request as `respond` says.
Future<(HttpServer, List<_Received>)> _serve(FutureOr<(int, String, String)> Function(String path) respond) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final received = <_Received>[];
  server.listen((request) async {
    final body = await utf8.decodeStream(request);
    received.add((method: request.method, path: request.uri.path, contentType: request.headers.contentType?.mimeType, body: body));
    final (status, text, type) = await respond(request.uri.path);
    request.response
      ..statusCode = status
      ..headers.set('content-type', type)
      ..write(text);
    await request.response.close();
  });
  return (server, received);
}

String _url(HttpServer server, String path) => 'http://127.0.0.1:${server.port}$path';

void main() {
  test('posts JSON and answers the status and the parsed body', () async {
    final (server, received) = await _serve((_) => (200, '{"lease":"a.b.c","activationId":"act_1"}', 'application/json'));
    addTearDown(server.close);
    final answer = await PackageHttp().post(_url(server, '/v1/products/sluice/validate'), {'key': 'K', 'major': 1}, timeout: _bound);
    expect(answer.status, 200);
    expect(answer.json, {'lease': 'a.b.c', 'activationId': 'act_1'});
    expect(received.single.method, 'POST');
    expect(received.single.path, '/v1/products/sluice/validate');
    expect(received.single.contentType, 'application/json');
    expect(jsonDecode(received.single.body), {'key': 'K', 'major': 1});
  });

  test('answers a 4xx and a 5xx as a response rather than throwing, a body that is not JSON as none', () async {
    final (server, _) = await _serve((path) => path == '/activate'
        ? (403, '{"error":"revoked"}', 'application/json')
        : (503, '<html>down</html>', 'text/html'));
    addTearDown(server.close);
    final refused = await PackageHttp().post(_url(server, '/activate'), {}, timeout: _bound);
    expect(refused.status, 403);
    expect(refused.json, {'error': 'revoked'});
    final down = await PackageHttp().post(_url(server, '/validate'), {}, timeout: _bound);
    expect((down.status, down.json), (503, null));
  });

  test('reads an empty body, and one that is not UTF-8, as none', () async {
    final (server, _) = await _serve((path) => (path == '/empty' ? 204 : 200, path == '/empty' ? '' : 'ÿ', 'application/json'));
    addTearDown(server.close);
    final empty = await PackageHttp().post(_url(server, '/empty'), {}, timeout: _bound);
    expect((empty.status, empty.json), (204, null));
    final latin = await PackageHttp().post(_url(server, '/latin'), {}, timeout: _bound);
    expect(latin.json, isNull);
  });

  test('sends a body with text outside ASCII as UTF-8', () async {
    final (server, received) = await _serve((_) => (200, '{}', 'application/json'));
    addTearDown(server.close);
    await PackageHttp().post(_url(server, '/activate'), {'name': 'Zoë \u{1F600}'}, timeout: _bound);
    expect(jsonDecode(received.single.body), {'name': 'Zoë \u{1F600}'});
  });

  test('throws, promptly, for a call that outlives its bound, and aborts it', () async {
    // A server that takes the connection and never answers (a captive portal, a dead proxy).
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final closed = Completer<void>();
    server.listen((socket) => socket.listen((_) {}, onDone: () {
          if (!closed.isCompleted) closed.complete();
          socket.destroy();
        }, onError: (_) {}));
    final started = DateTime.now();
    await expectLater(
      PackageHttp().post('http://127.0.0.1:${server.port}/validate', {}, timeout: const Duration(milliseconds: 300)),
      throwsA(anything),
    );
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
    // The connection is let go, not left running.
    await closed.future.timeout(const Duration(seconds: 5));
  });

  test('does not abandon a call that answers inside its bound', () async {
    final (server, _) = await _serve((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      return (200, '{"ok":true}', 'application/json');
    });
    addTearDown(server.close);
    final answer = await PackageHttp().post(_url(server, '/validate'), {}, timeout: const Duration(seconds: 3));
    expect(answer.json, {'ok': true});
  });

  test('throws when nothing is listening', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    await expectLater(PackageHttp().post('http://127.0.0.1:$port/validate', {}, timeout: _bound), throwsA(anything));
  });

  test('bounds every call by default, at 15 s', () {
    expect(defaultHttpTimeout, const Duration(seconds: 15));
    expect(const LicenseConfig(product: 'sluice', apiBaseUrl: 'https://api.test').httpTimeout, defaultHttpTimeout);
  });
}
