/// Licence files (the SDK contract, section 10; the reference's shared license-file.ts
/// and license-file-text.ts, and its SDK's license-file.ts): the container, verifying a
/// token, judging it for this app, and the status a stored offline file gives.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'entitlements.dart';
import 'json.dart';
import 'jws.dart';
import 'keys.dart';
import 'lease.dart';
import 'status.dart';
import 'types.dart';

/// The most a licence file may be, in bytes.
const int maxLicenseFileBytes = 16384;

/// The file's extension, for an app's open dialog and drop filter.
const String licenseFileExtension = '.kglicense';

/// The media type of a licence file attached to an email.
const String licenseFileMediaType = 'application/vnd.keygrant.license';

const String _fileHeaderStart = '{"alg":"EdDSA","typ":"kglicense+jwt","kid":"';

/// The token a licence file holds, or null when it is no licence file's
/// container (10.4): more than [maxLicenseFileBytes]; not UTF-8; or not
/// exactly one line once each line (split on LF) is trimmed of spaces, tabs
/// and CRs and empty and `#` lines are left out. A leading byte-order mark is
/// ignored. `content` is text (read as its UTF-8) or bytes.
String? licenseFileToken(Object content) {
  if (content is String && content.length > maxLicenseFileBytes) return null;
  final List<int> bytes;
  if (content is String) {
    bytes = utf8.encode(content);
  } else if (content is List<int>) {
    bytes = content;
  } else if (content is ByteBuffer) {
    bytes = content.asUint8List();
  } else {
    return null;
  }
  if (bytes.length > maxLicenseFileBytes) return null;
  final String text;
  try {
    // Strict, and a leading byte-order mark dropped (Dart's decoder drops one, as TextDecoder does).
    text = utf8.decode(bytes);
  } on FormatException {
    return null;
  }
  final lines = [
    for (final line in text.split('\n'))
      if (_edges(line) case final trimmed when trimmed.isNotEmpty && !trimmed.startsWith('#')) trimmed,
  ];
  return lines.length == 1 ? lines.single : null;
}

final RegExp _lineEdges = RegExp(r'^[ \t\r]+|[ \t\r]+$');
String _edges(String line) => line.replaceAll(_lineEdges, '');

/// A licence file's claims as a verifier reads them.
final class LicenseFileClaims {
  const LicenseFileClaims({
    required this.kind,
    required this.fid,
    required this.sub,
    required this.product,
    this.name,
    this.email,
    required this.iat,
    this.test,
    this.major,
    this.minMajor,
    this.ent = const {},
  });

  final LicenseFileKind kind;

  /// The file's id: what a denylist names it by.
  final String fid;

  /// The licence key.
  final String sub;
  final String product;
  final String? name;
  final String? email;
  final int iat;
  final bool? test;

  /// An offline file's range (absent on a key file).
  final int? major;
  final int? minMajor;
  final Map<String, Entitlement> ent;

  LicensedTo get licensedTo => LicensedTo(name: name, email: email);

  /// The claims a payload holds, or null when they do not match (`bad-claims`).
  static LicenseFileClaims? parse(Object? json) {
    final c = json is List ? null : asObject(json);
    if (c == null || c['iss'] != 'keygrant') return null;
    final kind = switch (c['kind']) { 'key' => LicenseFileKind.key, 'offline' => LicenseFileKind.offline, _ => null };
    final fid = _text(c['fid']), sub = _text(c['sub']), product = _text(c['product']);
    final iat = wholeOf(c['iat']);
    if (kind == null || fid == null || sub == null || product == null || iat == null || iat < 0) return null;
    final name = c['name'], email = c['email'], test = c['test'];
    if (c.containsKey('name') && _text(name) == null) return null;
    if (c.containsKey('email') && _text(email) == null) return null;
    if (c.containsKey('test') && test is! bool) return null;
    if (name == null && email == null) return null;
    if (kind == LicenseFileKind.key) {
      return LicenseFileClaims(kind: kind, fid: fid, sub: sub, product: product, name: name as String?, email: email as String?, iat: iat, test: test as bool?);
    }
    final major = wholeOf(c['major']), minMajor = wholeOf(c['minMajor']);
    if (major == null || major <= 0) return null;
    if (c.containsKey('minMajor') && (minMajor == null || minMajor <= 0)) return null;
    return LicenseFileClaims(
      kind: kind,
      fid: fid,
      sub: sub,
      product: product,
      name: name as String?,
      email: email as String?,
      iat: iat,
      test: test as bool?,
      major: major,
      minMajor: minMajor,
      ent: entitlementsOf(c['ent']),
    );
  }

  Map<String, Object?> toJson() => withoutNulls({
        'iss': 'keygrant',
        'kind': kind.wire,
        'fid': fid,
        'sub': sub,
        'product': product,
        'name': name,
        'email': email,
        'iat': iat,
        'test': test,
        'major': major,
        'minMajor': minMajor,
        'ent': kind == LicenseFileKind.offline ? entitlementsJson(ent) : null,
      });
}

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

/// What verifying a licence file says: valid with its claims, or why not.
final class LicenseFileVerifyResult {
  const LicenseFileVerifyResult.valid(LicenseFileClaims this.claims) : reason = null;
  const LicenseFileVerifyResult.invalid(String this.reason) : claims = null;

  /// `malformed`, `not-a-license-file`, `unknown-key`, `bad-signature` or `bad-claims`.
  final String? reason;
  final LicenseFileClaims? claims;

  bool get valid => reason == null;

  Map<String, Object?> toJson() => valid ? {'valid': true, 'claims': claims!.toJson()} : {'valid': false, 'reason': reason};
}

/// Verify a licence file's token against a key set (10.2), in order: three
/// parts; a licence file's header; a canonical signature; the key it names in
/// the set; a 64-byte signature by THAT key; the claims.
Future<LicenseFileVerifyResult> verifyLicenseFile(String token, List<VerifyingKey> keys) async {
  final parts = token.split('.');
  if (parts.length != 3) return const LicenseFileVerifyResult.invalid('malformed');
  final [header, payload, signature] = parts;
  final kid = namedKeyId(header, _fileHeaderStart);
  if (kid == null) return const LicenseFileVerifyResult.invalid('not-a-license-file');
  final Uint8List sig;
  try {
    sig = b64urlDecode(signature);
  } on FormatException {
    return const LicenseFileVerifyResult.invalid('malformed');
  }
  final named = keys.where((k) => k.kid == kid);
  if (named.isEmpty) return const LicenseFileVerifyResult.invalid('unknown-key');
  if (!await ed25519Verifies(named.first.key, sig, utf8.encode('$header.$payload'))) {
    return const LicenseFileVerifyResult.invalid('bad-signature');
  }
  final claims = LicenseFileClaims.parse(payloadJson(payload));
  return claims == null ? const LicenseFileVerifyResult.invalid('bad-claims') : LicenseFileVerifyResult.valid(claims);
}

/// What a licence file says about this app, offline (10.5): taken, or why not
/// (a failure once the signature held keeps the claims).
final class LicenseFileCheck {
  const LicenseFileCheck.taken(LicenseFileClaims this.claims) : reason = null;
  const LicenseFileCheck.refused(LicenseFileError this.reason, [this.claims]);

  final LicenseFileError? reason;
  final LicenseFileClaims? claims;

  bool get ok => reason == null;

  Map<String, Object?> toJson() =>
      ok ? {'ok': true, 'kind': claims!.kind.wire, 'test': claims!.test == true} : {'ok': false, 'reason': reason!.wire};
}

/// A verified licence file held to this product, this build and the denylist.
LicenseFileCheck checkLicenseFile(LicenseFileVerifyResult v, String product, int major, List<String> revoked) {
  final claims = v.claims;
  if (claims == null) {
    return LicenseFileCheck.refused(switch (v.reason) {
      'unknown-key' => LicenseFileError.unknownKey,
      'bad-signature' => LicenseFileError.badSignature,
      'not-a-license-file' => LicenseFileError.notALicenseFile,
      _ => LicenseFileError.malformed,
    });
  }
  if (claims.product != product) return LicenseFileCheck.refused(LicenseFileError.wrongProduct, claims);
  if (revoked.contains(claims.fid)) return LicenseFileCheck.refused(LicenseFileError.revokedFile, claims);
  if (claims.kind == LicenseFileKind.offline) {
    if (major < (claims.minMajor ?? 1)) return LicenseFileCheck.refused(LicenseFileError.outdated, claims);
    if (major > claims.major!) return LicenseFileCheck.refused(LicenseFileError.upgrade, claims);
  }
  return LicenseFileCheck.taken(claims);
}

/// The status a STORED offline licence file gives (10.5), `source: file` on every one.
LicenseStatus licenseFileStatus(LicenseFileCheck check) {
  final claims = check.claims;
  const file = LicenseSource.file;
  if (check.ok && claims!.kind == LicenseFileKind.offline) {
    return LicenseStatus(LicenseState.licensed,
        key: claims.sub, source: file, licensedTo: claims.licensedTo, test: claims.test == true, entitlements: claims.ent);
  }
  final reason = switch (check.reason) {
    LicenseFileError.revokedFile => LicenseReason.revokedFile,
    LicenseFileError.upgrade => LicenseReason.upgrade,
    LicenseFileError.outdated => LicenseReason.outdated,
    _ => null,
  };
  if (claims != null && reason != null) {
    return LicenseStatus(LicenseState.invalid, reason: reason, key: claims.sub, source: file, licensedTo: claims.licensedTo);
  }
  if (check.reason == LicenseFileError.unknownKey) {
    return const LicenseStatus(LicenseState.invalid, reason: LicenseReason.unknownKey, source: file);
  }
  return const LicenseStatus(LicenseState.invalid, reason: LicenseReason.tampered, source: file);
}
