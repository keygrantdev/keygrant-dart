/// The HTTP surface the SDK talks to KeyGrant through, and its default, over
/// `package:http`: every call bounded.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// How long a request may take before it is abandoned, unless the call or the
/// configuration says otherwise.
const Duration defaultHttpTimeout = Duration(seconds: 15);

/// What a POST came back with: its HTTP status, and its body as JSON (null
/// when it had none, or none that parses).
final class HttpResponse {
  const HttpResponse(this.status, [this.json]);

  final int status;
  final Object? json;
}

/// POST JSON. Answers every status (a 4xx and a 5xx included) rather than
/// throwing; throws only when there was no answer (no network, a timeout).
/// `timeout` is how long the call may take: an adapter that ignores it is still
/// held to it by the SDK.
abstract interface class HttpAdapter {
  Future<HttpResponse> post(String url, Map<String, Object?> body, {required Duration timeout});
}

/// HTTP over `package:http`, every call bounded: abandoned (the request
/// aborted) and thrown once `timeout` has passed, which the SDK treats as no
/// network. Without a bound a network that accepts a connection and never
/// answers (a captive portal, a dead proxy) would hold a check-in for minutes.
final class PackageHttp implements HttpAdapter {
  PackageHttp({http.Client Function()? client}) : _client = client ?? http.Client.new;

  final http.Client Function() _client;

  @override
  Future<HttpResponse> post(String url, Map<String, Object?> body, {required Duration timeout}) async {
    final abort = Completer<void>();
    final timer = Timer(timeout, () => abort.isCompleted ? null : abort.complete());
    final client = _client();
    try {
      final request = http.AbortableRequest('POST', Uri.parse(url), abortTrigger: abort.future)
        ..headers['content-type'] = 'application/json'
        ..body = jsonEncode(body);
      final response = await http.Response.fromStream(await client.send(request)).timeout(timeout);
      return HttpResponse(response.statusCode, _json(response.bodyBytes));
    } finally {
      timer.cancel();
      client.close();
    }
  }

  static Object? _json(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
  }
}
