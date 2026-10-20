// The harness the behaviour suites share (the reference's license.fixture.ts): a
// licence over in-memory storage, a fixed clock, a scripted HTTP server and a
// stash, with the product's signing key to sign leases with.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/jws.dart';
import 'package:keygrant/src/core/keys.dart' show keyId;

const int now0 = 1757000000000;
const int day = 86400000;
const String product = 'sluice';
const String key1 = 'SLUICE-AAAA-BBBB-CCCC-DDDD';

typedef Handler = FutureOr<HttpResponse> Function(Map<String, Object?> body);

/// A recorded request.
final class Call {
  Call(this.action, this.body, this.timeout);
  final String action;
  final Map<String, Object?> body;
  final Duration timeout;
}

/// A scripted server: a handler per action; a 404 for any other.
final class FakeHttp implements HttpAdapter {
  final Map<String, Handler> handlers = {};
  final List<Call> calls = [];

  /// Every request throws: no network.
  bool fail = false;

  /// No request ever answers: a network that takes the connection and says nothing.
  bool hang = false;
  final List<({String action, int count, Completer<void> done})> _waiting = [];

  FakeHttp on(String action, Handler handler) {
    handlers[action] = handler;
    return this;
  }

  @override
  Future<HttpResponse> post(String url, Map<String, Object?> body, {required Duration timeout}) async {
    final action = url.split('/v1/products/$product/').last;
    calls.add(Call(action, jsonDecode(jsonEncode(body)) as Map<String, Object?>, timeout));
    _waiting.removeWhere((w) {
      if (count(w.action) < w.count) return false;
      w.done.complete();
      return true;
    });
    if (fail) throw Exception('network down');
    if (hang) return Completer<HttpResponse>().future;
    final handler = handlers[action];
    return handler == null ? const HttpResponse(404, {'error': 'unknown'}) : await handler(body);
  }

  bool called(String action) => calls.any((c) => c.action == action);
  int count(String action) => calls.where((c) => c.action == action).length;

  /// The body of the first `action` call.
  Map<String, Object?> bodyOf(String action) => calls.firstWhere((c) => c.action == action).body;

  /// The body of the last `action` call.
  Map<String, Object?> lastBodyOf(String action) => calls.lastWhere((c) => c.action == action).body;

  /// Completes once `n` calls of `action` have been made.
  Future<void> whenCalled(String action, [int n = 1]) {
    if (count(action) >= n) return Future.value();
    final done = Completer<void>();
    _waiting.add((action: action, count: n, done: done));
    return done.future;
  }
}

/// In-memory storage with every failure a disk can have.
final class MemoryStorage extends StorageAdapter {
  MemoryStorage([this.stored]);

  StoredState? stored;
  int reads = 0;
  int writes = 0;
  bool failWrites = false;
  int? failReadAt;
  bool hangNextRead = false;
  Completer<void>? _held;
  final List<({int count, Completer<void> done})> _waiting = [];

  @override
  Future<StoredState?> read({bool readOnly = false}) async {
    reads++;
    if (reads == failReadAt) throw const FileSystemLikeError('EBUSY: held by a scan');
    if (hangNextRead) {
      hangNextRead = false;
      return Completer<StoredState?>().future;
    }
    return stored;
  }

  @override
  Future<void> write(StoredState state) async {
    writes++;
    _waiting.removeWhere((w) {
      if (w.count > writes) return false;
      w.done.complete();
      return true;
    });
    if (failWrites) throw const FileSystemLikeError('EBUSY: the disk said no');
    final held = _held;
    if (held != null) {
      _held = null;
      await held.future;
    }
    stored = state;
  }

  /// The next write is held inside the adapter with the whole state it was
  /// handed, which lands when released; returns what releases it.
  void Function() holdNextWrite() {
    final held = Completer<void>();
    _held = held;
    return held.complete;
  }

  /// The `nth` read from now fails.
  void failRead(int nth) => failReadAt = reads + nth;

  Future<void> whenWritten([int count = 1]) {
    if (writes >= count) return Future.value();
    final done = Completer<void>();
    _waiting.add((count: count, done: done));
    return done.future;
  }
}

final class FileSystemLikeError implements Exception {
  const FileSystemLikeError(this.message);
  final String message;
  @override
  String toString() => message;
}

final class FakeClock implements LicenseClock {
  int value = now0;
  @override
  int now() => value;
}

final class FakeStash implements RegistryStash {
  int? start;
  bool failRead = false;
  bool failWrite = false;
  @override
  Future<int?> readTrialStart() async {
    if (failRead) throw Exception('the registry said no');
    return start;
  }

  @override
  Future<void> writeTrialStart(int ms) async {
    if (failWrite) throw Exception('the registry said no');
    start = ms;
  }
}

/// A fingerprinter with only `get()`: no kind, so seats are never held.
final class PlainFingerprinter extends Fingerprinter {
  const PlainFingerprinter([this.fingerprint = 'fp-test']);
  final String fingerprint;
  @override
  Future<String> get() async => fingerprint;
}

/// A fingerprinter that answers what a test sets.
final class ScriptedFingerprinter extends Fingerprinter {
  ScriptedFingerprinter(this.identity);
  DeviceIdentity identity;
  int reads = 0;
  Duration? lastTimeout;
  @override
  Future<String> get() async => identity.fingerprint ?? (throw StateError('none'));
  @override
  Future<DeviceIdentity> identify(Duration timeout) async {
    reads++;
    lastTimeout = timeout;
    return identity;
  }
}

/// A product signing key, and leases and files signed with it.
final class Signer {
  Signer._(this._pair, this.publicJwk, this.kid);

  static Future<Signer> create() async {
    final pair = await Ed25519().newKeyPair();
    final x = b64urlEncode((await pair.extractPublicKey()).bytes);
    final jwk = {'kty': 'OKP', 'crv': 'Ed25519', 'x': x};
    return Signer._(pair, jwk, keyIdOf(jwk));
  }

  final SimpleKeyPair _pair;
  final Map<String, Object?> publicJwk;
  final String kid;

  Future<String> compact(String header, Map<String, Object?> claims) async {
    final input = '${b64urlEncode(utf8.encode(header))}.${b64urlEncode(utf8.encode(jsonEncode(claims)))}';
    final signature = await Ed25519().sign(utf8.encode(input), keyPair: _pair);
    return '$input.${b64urlEncode(signature.bytes)}';
  }

  /// A lease for `sub`, signed at `at` (ms) for `ttlSeconds`.
  Future<String> lease(String sub,
      {String model = 'perpetual',
      int ttlSeconds = 30 * 86400,
      int at = now0,
      String aid = 'act_1',
      String productSlug = product,
      int major = 1,
      Map<String, Object?> extra = const {}}) {
    final iat = at ~/ 1000;
    return compact('{"alg":"EdDSA","typ":"JWT","kid":"$kid"}', {
      'iss': 'keygrant',
      'sub': sub,
      'product': productSlug,
      'aid': aid,
      'model': model,
      'lim': 3,
      'major': major,
      'ent': <String, Object?>{},
      'iat': iat,
      'exp': iat + ttlSeconds,
      ...extra,
    });
  }

  /// A licence file's token.
  Future<String> file(Map<String, Object?> claims) =>
      compact('{"alg":"EdDSA","typ":"kglicense+jwt","kid":"$kid"}', {'iss': 'keygrant', ...claims});
}

String keyIdOf(Map<String, Object?> jwk) => keyId(jwk);

/// Everything a behaviour test holds.
final class Harness {
  Harness._(this.signer, this.storage, this.http, this.clock, this.stash, this.config);

  static Future<Harness> create({
    StoredState? initial,
    int major = 1,
    String? deviceName,
    Duration httpTimeout = const Duration(seconds: 15),
    Fingerprinter? fingerprinter,
    bool deviceHold = true,
    List<String> revoked = const [],
    Timing timing = Timing.standard,
  }) async {
    final signer = await Signer.create();
    final storage = MemoryStorage(initial);
    final http = FakeHttp();
    final clock = FakeClock();
    final stash = FakeStash();
    final config = LicenseConfig(
      product: product,
      apiBaseUrl: 'https://api.test/',
      publicJwk: signer.publicJwk,
      major: major,
      deviceName: deviceName,
      httpTimeout: httpTimeout,
      deviceHold: deviceHold,
      revokedLicenseFiles: revoked,
      adapters: LicenseAdapters(
        storage: storage,
        registry: stash,
        clock: clock,
        fingerprinter: fingerprinter ?? const PlainFingerprinter(),
        http: http,
      ),
    );
    final h = Harness._(signer, storage, http, clock, stash, config);
    h.license = KeyGrantLicense.timed(config, timing);
    return h;
  }

  final Signer signer;
  final MemoryStorage storage;
  final FakeHttp http;
  final FakeClock clock;
  final FakeStash stash;
  final LicenseConfig config;
  late KeyGrantLicense license;

  /// Another build of the app on this device: the same storage and server, another major.
  KeyGrantLicense licenseFor(int major, {Timing timing = Timing.standard}) => KeyGrantLicense.timed(
      LicenseConfig(
        product: product,
        apiBaseUrl: config.apiBaseUrl,
        publicJwk: signer.publicJwk,
        major: major,
        adapters: config.adapters,
      ),
      timing);

  StoredState? get stored => storage.stored;
  Map<String, Object?> get storedJson => storage.stored?.toJson() ?? const {};
  set stored(StoredState? state) => storage.stored = state;

  /// A stored activation of `key1` holding `lease`.
  void hold(String lease, [Map<String, Object?> more = const {}]) {
    storage.stored = StoredState.fromJson({'key': key1, 'activationId': 'act_1', 'lease': lease, ...more});
  }

  /// The server activates with `lease`.
  void activates(String lease, {String activationId = 'act_1'}) =>
      http.on('activate', (_) => HttpResponse(200, {'lease': lease, 'activationId': activationId}));

  /// The server renews with `lease`.
  void renews(String lease) => http.on('validate', (_) => HttpResponse(200, {'lease': lease}));
}
