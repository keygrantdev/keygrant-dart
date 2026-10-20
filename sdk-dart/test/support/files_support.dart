// What the licence-file suites share (the reference's license-file.fixture.ts): Ada's
// offline file and key file signed with the harness's key, a file's text, the
// statuses a file gives, and the harness's app rebuilt as major 2.

import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';

import 'harness.dart';

const String adaName = 'Ada Lovelace';
const String adaEmail = 'ada@example.com';
const LicensedTo ada = LicensedTo(name: adaName, email: adaEmail);

/// `claims` with `over` laid on it; a null member of `over` removes the claim.
Map<String, Object?> _laid(Map<String, Object?> claims, Map<String, Object?> over) {
  final out = {...claims};
  for (final MapEntry(:key, :value) in over.entries) {
    if (value == null) {
      out.remove(key);
    } else {
      out[key] = value;
    }
  }
  return out;
}

/// Ada's OFFLINE file (`lf_1`, majors 1 to 3, issued at now0), `over` laid on its claims.
Future<String> offlineFile(Harness h, [Map<String, Object?> over = const {}]) => h.signer.file(_laid({
      'kind': 'offline',
      'fid': 'lf_1',
      'sub': key1,
      'product': product,
      'name': adaName,
      'email': adaEmail,
      'major': 3,
      'ent': <String, Object?>{},
      'iat': now0 ~/ 1000,
    }, over));

/// Ada's KEY file (`lf_2`, the key in lower case, her email alone), `over` laid on its claims.
Future<String> keyFile(Harness h, [Map<String, Object?> over = const {}]) => h.signer.file(_laid({
      'kind': 'key',
      'fid': 'lf_2',
      'sub': key1.toLowerCase(),
      'product': product,
      'email': adaEmail,
      'iat': now0 ~/ 1000,
    }, over));

/// A licence file's text as the server writes one: notes, then the token on a
/// line of its own, CRLF as a mail gateway may leave it.
String fileText(String token) => '# KeyGrant license file\r\n# Product: $product\r\n\r\n$token\r\n';

/// `token` with its payload swapped for `other`'s, under its own header and signature.
String payloadSwapped(String token, String other) {
  final parts = token.split('.');
  return '${parts[0]}.${other.split('.')[1]}.${parts[2]}';
}

/// What a status gives for Ada's offline file.
const LicenseStatus fileLicensed = LicenseStatus(LicenseState.licensed, key: key1, source: LicenseSource.file, licensedTo: ada);

/// A stored file's status that does not license this build, with whose it is.
LicenseStatus fileInvalid(LicenseReason reason) =>
    LicenseStatus(LicenseState.invalid, reason: reason, key: key1, source: LicenseSource.file, licensedTo: ada);

/// A stored file's status with nothing of the file read.
LicenseStatus fileUnread(LicenseReason reason) => LicenseStatus(LicenseState.invalid, reason: reason, source: LicenseSource.file);

/// `key1` licensed by its lease.
const LicenseStatus keyLicensed = LicenseStatus(LicenseState.licensed, key: key1);

/// The harness's app as major 2 (unless said), its adapters kept, with
/// `revoked` as its denylist and `keys` as its key set.
KeyGrantLicense fileApp(Harness h,
        {List<String> revoked = const [], List<Map<String, Object?>>? keys, int major = 2, Timing timing = Timing.standard}) =>
    KeyGrantLicense.timed(
        LicenseConfig(
          product: product,
          apiBaseUrl: h.config.apiBaseUrl,
          publicJwk: keys == null ? h.signer.publicJwk : null,
          publicJwks: keys,
          major: major,
          httpTimeout: h.config.httpTimeout,
          revokedLicenseFiles: revoked,
          adapters: h.config.adapters,
        ),
        timing);

/// A licence lease for `key1` on act_1, covering majors 1 to 3, for `ttlSeconds` (thirty days).
Future<String> leaseTo3(Harness h, {int at = now0, int ttlSeconds = 30 * 86400, Map<String, Object?> extra = const {}}) =>
    h.signer.lease(key1, major: 3, at: at, ttlSeconds: ttlSeconds, extra: extra);

/// A stored state of `fields`.
StoredState stateOf(Map<String, Object?> fields) => StoredState.fromJson(fields);
