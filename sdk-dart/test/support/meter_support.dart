// What the metered-uses suites share (the reference's meters.fixture.ts,
// MeterSupport.swift, MeterStorages.swift): a key's lease carrying meters, a
// harness holding it, the server's answers to a `use`, and storages that let a
// second process save in between.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/jws.dart';

import 'harness.dart';

const int minute = 60000;
const int hour = 3600000;
const int monthSeconds = 30 * 86400;

/// Long enough ago that the journal's wait for an entry is over.
const int longAgo = now0 - 2 * hour;

/// A key with 100 exports, 90 of them left, a device allowance of 10, and 5 renders a billing period.
const Map<String, Object?> usualMeters = {
  'exports': {'left': 90, 'total': 100, 'offline': 10},
  'renders': {'left': 5, 'total': 5, 'offline': 0, 'resets': true},
};

/// The timings of a test whose call waits behind one that has not finished:
/// the HTTP bound (1.5 s, given to the harness) and a short grace.
const Timing behind = Timing(
  lockGrace: Duration(milliseconds: 50),
  machineId: Duration(milliseconds: 200),
  activateMachineId: Duration(milliseconds: 600),
  identifySlack: Duration(milliseconds: 300),
);

/// A 22-character id made of one letter.
String spendId(String letter) => letter * 22;

/// An id of 22 characters from a number, with a letter to tell families apart.
String numbered(int i, [String letter = 'k']) => '${letter * (22 - '$i'.length)}$i';

/// A journal entry of `meter` (exports), under `id` (all A).
SpendEntry entry(SpendKind kind, int n, int at, {String? id, String meter = 'exports'}) =>
    SpendEntry(id: id ?? spendId('A'), meter: meter, n: n, at: at, kind: kind);

/// A licence lease for `key1` on `act_1`, covering majors 1 to 3, with `met`
/// (none for null), signed at `at` for a month, `over` laid on its claims.
Future<String> meteredLease(Harness h,
        {Map<String, Object?>? met = usualMeters, int at = now0, int ttlSeconds = monthSeconds, Map<String, Object?> over = const {}}) =>
    h.signer.lease(key1, model: 'subscription', major: 3, at: at, ttlSeconds: ttlSeconds, extra: {if (met != null) 'met': met, ...over});

/// A harness whose storage holds `key1` activated on `act_1` with a lease
/// carrying `met`, and `state` laid beside it (fields as the state file writes them).
Future<Harness> holding({
  Map<String, Object?>? met = usualMeters,
  int major = 1,
  Duration httpTimeout = const Duration(seconds: 15),
  Timing timing = Timing.standard,
  Fingerprinter? fingerprinter,
  bool deviceHold = true,
  Map<String, Object?> state = const {},
}) async {
  final h = await Harness.create(
      major: major, httpTimeout: httpTimeout, timing: timing, fingerprinter: fingerprinter, deviceHold: deviceHold);
  h.stored = StoredState.fromJson(
      {'key': key1, 'activationId': 'act_1', 'lease': await meteredLease(h, met: met), 'lastSeen': now0, ...state});
  return h;
}

/// A harness holding the usual meters and `spends` in its journal.
Future<Harness> holdingJournal(List<SpendEntry> spends,
        {Duration httpTimeout = const Duration(seconds: 15), Timing timing = Timing.standard, Map<String, Object?> state = const {}}) =>
    holding(httpTimeout: httpTimeout, timing: timing, state: {'spends': journalJson(spends), ...state});

/// The no-answer wait running from now0: a spend the allowance covers asks nothing.
const Map<String, Object?> waitRunning = {'backoffSince': now0, 'backoffMs': 60000};

List<Map<String, Object?>> journalJson(List<SpendEntry> spends) => [for (final e in spends) e.toJson()];

/// The server's answer to a spend that landed: what is left of `exports` now, at `at`.
HttpResponse spent(int left, {int at = now0}) => HttpResponse(200, {
      'spent': true,
      'meters': {
        'exports': {'left': left, 'total': 100, 'offline': 10}
      },
      'at': at,
    });

/// A `spent` answer for renders with 4 left.
HttpResponse rendersSpent({int at = now0}) => HttpResponse(200, {
      'spent': true,
      'at': at,
      'meters': {
        'renders': {'left': 4, 'total': 5, 'offline': 0, 'resets': true}
      },
    });

Matcher spentLeft(int left, {bool offline = false}) =>
    isA<UseSpent>().having((r) => r.left, 'left', left).having((r) => r.offline, 'offline', offline);

Matcher useRefused(UseError error, [int? left]) =>
    isA<UseRefused>().having((r) => r.error, 'error', error).having((r) => r.left, 'left', left);

/// The journal as `kind n`.
List<String> kindsAndCounts(List<SpendEntry> journal) => [for (final e in journal) '${e.kind.wire} ${e.n}'];

extension MeterHarness on Harness {
  /// The journal as stored now.
  List<SpendEntry> get journal => stored?.spends ?? const [];

  /// The body of the `nth` (from 0) `use` request, or an empty map.
  Map<String, Object?> useBody([int nth = 0]) {
    final bodies = [for (final c in http.calls) if (c.action == 'use') c.body];
    return nth < bodies.length ? bodies[nth] : const {};
  }

  /// The `spends` of the `nth` (from 0) validate request, or null when it carried none.
  Object? report([int nth = 0]) {
    final bodies = [for (final c in http.calls) if (c.action == 'validate') c.body];
    return nth < bodies.length ? bodies[nth]['spends'] : null;
  }

  /// The server renews with `lease`, or the usual metered lease.
  Future<void> renewing([String? lease]) async => renews(lease ?? await meteredLease(this));

  /// Another licence over this harness's clock, server, fingerprinter and key, whose storage is `storage`.
  KeyGrantLicense appOver(StorageAdapter storage, {int major = 1, Timing timing = Timing.standard}) => KeyGrantLicense.timed(
      LicenseConfig(
        product: product,
        apiBaseUrl: config.apiBaseUrl,
        publicJwk: signer.publicJwk,
        major: major,
        httpTimeout: config.httpTimeout,
        adapters: LicenseAdapters(
            storage: storage, registry: stash, clock: clock, fingerprinter: config.adapters.fingerprinter, http: http),
      ),
      timing);
}

/// A storage with a merge of its own (`update`, as the default file storage
/// has) that lets a second process save before this one's first merge.
final class Racing extends StorageAdapter {
  Racing(Harness h, this._theirs, {this.dropFigures = false, this.failReadsAfter = false}) : inner = h.storage;

  final MemoryStorage inner;
  List<SpendEntry>? _theirs;
  final bool dropFigures;
  final bool failReadsAfter;
  bool _saved = false;

  @override
  Future<StoredState?> read({bool readOnly = false}) async {
    if (failReadsAfter && _saved) throw const FileSystemLikeError('EIO: read');
    return inner.read(readOnly: readOnly);
  }

  @override
  Future<void> write(StoredState state) => inner.write(state);

  @override
  Future<void> update(StoredState Function(StoredState latest) merge) async {
    var latest = inner.stored ?? StoredState.empty;
    final theirs = _theirs;
    if (theirs != null) {
      _theirs = null;
      latest = StoredState.fromJson({
        ...latest.toJson(),
        'spends': journalJson(theirs),
        'rev': 9,
        if (dropFigures) 'meterFigures': null,
      });
    }
    await inner.write(merge(latest));
    _saved = true;
  }
}

/// A storage that fails every save until the disk is back, then the first save
/// after that, and lets another process's entry in before the `injectAt`th.
final class Flaky extends StorageAdapter {
  Flaky(Harness h, {this.injectAt = 0}) : inner = h.storage;

  final MemoryStorage inner;
  final int injectAt;
  bool _failing = true;
  int _saves = 0;

  void diskBack() => _failing = false;

  @override
  Future<StoredState?> read({bool readOnly = false}) => inner.read(readOnly: readOnly);

  @override
  Future<void> write(StoredState state) => inner.write(state);

  @override
  Future<void> update(StoredState Function(StoredState latest) merge) async {
    if (_failing) throw const FileSystemLikeError('EBUSY: save');
    final save = ++_saves;
    if (save == 1) throw const FileSystemLikeError('EBUSY: save');
    var latest = inner.stored ?? StoredState.empty;
    if (save == injectAt) {
      latest = StoredState.fromJson({
        ...latest.toJson(),
        'spends': journalJson([entry(SpendKind.offline, 1, now0 - 5, id: spendId('Y'))]),
      });
    }
    await inner.write(merge(latest));
  }
}

/// A fingerprinter that cannot tell who the device is.
final class BlindFingerprinter extends Fingerprinter {
  const BlindFingerprinter();
  @override
  Future<String> get() async => throw StateError('no machine id');
}

/// A signer of leases whose payload is exactly the JSON text given (a figure
/// `4.0`, `1e1` or `1e400` stays as it is), and an app that trusts its key.
final class RawSigner {
  RawSigner._(this._pair, this.publicJwk, this.kid);

  static Future<RawSigner> create() async {
    final pair = await Ed25519().newKeyPair();
    final x = b64urlEncode((await pair.extractPublicKey()).bytes);
    final jwk = {'kty': 'OKP', 'crv': 'Ed25519', 'x': x};
    return RawSigner._(pair, jwk, keyIdOf(jwk));
  }

  final SimpleKeyPair _pair;
  final Map<String, Object?> publicJwk;
  final String kid;

  /// A metered lease for `key1` on act_1 whose `met` is the JSON text `met`.
  Future<String> lease(String met) async {
    const iat = now0 ~/ 1000;
    final payload = '{"iss":"keygrant","sub":"$key1","product":"$product","aid":"act_1","model":"subscription",'
        '"lim":3,"major":3,"ent":{},"met":$met,"iat":$iat,"exp":${iat + monthSeconds}}';
    final input = '${b64urlEncode(utf8.encode('{"alg":"EdDSA","typ":"JWT","kid":"$kid"}'))}.${b64urlEncode(utf8.encode(payload))}';
    final signature = await Ed25519().sign(utf8.encode(input), keyPair: _pair);
    return '$input.${b64urlEncode(signature.bytes)}';
  }

  /// A licence over `h`'s adapters that trusts this key.
  KeyGrantLicense app(Harness h) => KeyGrantLicense.timed(
      LicenseConfig(product: product, apiBaseUrl: h.config.apiBaseUrl, publicJwk: publicJwk, adapters: h.config.adapters),
      Timing.standard);
}
