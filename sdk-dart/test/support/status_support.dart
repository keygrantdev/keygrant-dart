// What the status and renewal suites share beside the harness: leases with
// any claims (one whose header names no key among them), a stored state from
// its JSON, and a status as its JSON, to compare as the reference's toEqual does.

import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/keys.dart' show fingerprintClaim;

import 'harness.dart';

export 'package:keygrant/src/core/keys.dart' show fingerprintClaim;

/// A lease's claims as `Signer.lease` writes them.
Map<String, Object?> leaseClaims(String sub,
    {String model = 'perpetual',
    int ttlSeconds = 30 * 86400,
    int at = now0,
    String aid = 'act_1',
    String productSlug = product,
    int major = 1,
    Map<String, Object?> extra = const {}}) {
  final iat = at ~/ 1000;
  return {
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
  };
}

/// A lease whose header names no key, signed by `signer`.
Future<String> unnamedLease(Signer signer, String sub,
        {int ttlSeconds = 30 * 86400, int at = now0, String productSlug = product}) =>
    signer.compact('{"alg":"EdDSA","typ":"JWT"}', leaseClaims(sub, ttlSeconds: ttlSeconds, at: at, productSlug: productSlug));

/// A lease for `key1` held to the machine whose fingerprint is `device`
/// (none: a lease with no device claim).
Future<String> machineLease(Harness h, {String? device = 'fp-test', String sub = key1, String aid = 'act_1', int at = now0}) =>
    h.signer.lease(sub,
        aid: aid, at: at, extra: device == null ? const {} : {'fp': fingerprintClaim(device), 'fpk': 'machine'});

/// Store the state `json` holds.
void store(Harness h, Map<String, Object?> json) => h.stored = StoredState.fromJson(json);

/// A stored activation of `key1` holding `lease`, its major heard, last seen now.
void holding(Harness h, String lease, [Map<String, Object?> more = const {}]) =>
    store(h, {'key': key1, 'activationId': 'act_1', 'lease': lease, 'checkedMajor': 1, 'lastSeen': now0, ...more});

/// How many validates were asked.
int validates(Harness h) => h.http.count('validate');

/// A status as the reference's JSON writes it.
Map<String, Object?> js(LicenseStatus status) => status.toJson();

/// The licence's status as JSON.
Future<Map<String, Object?>> statusOf(KeyGrantLicense license) async => (await license.status()).toJson();

/// The licence's forced status as JSON.
Future<Map<String, Object?>> refreshOf(KeyGrantLicense license) async => (await license.refresh()).toJson();

/// The JSON of `invalid` for `reason`, with the key.
Map<String, Object?> invalid(String reason, [String key = key1]) => {'state': 'invalid', 'reason': reason, 'key': key};

const Map<String, Object?> licensedJson = {'state': 'licensed', 'key': key1};
const Map<String, Object?> expiredOffline = {'state': 'expired', 'reason': 'offline', 'key': key1};

/// The server answers a validate with `status` and `json`.
void answers(Harness h, int status, [Object? json]) => h.http.on('validate', (_) => HttpResponse(status, json));

/// The server refuses a validate with `error`.
void refuses(Harness h, String error) => answers(h, 403, {'error': error});
