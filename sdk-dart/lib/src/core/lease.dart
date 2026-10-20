/// The lease (the SDK contract, section 2; the reference's lease.ts and crypto.ts):
/// its claims as a verifier reads them, the meters a lease signs, and
/// verifying one offline against a key set.
library;

import 'dart:convert';

import 'entitlements.dart';
import 'json.dart';
import 'jws.dart';
import 'keys.dart';
import 'meter_types.dart';
import 'types.dart';

/// The lease's `major` claim for a key with no upper bound.
const int openMajor = 1000000;

/// The header the server writes for a lease that names its key, up to the id.
const String _namedHeaderStart = '{"alg":"EdDSA","typ":"JWT","kid":"';

/// A lease's claims as a verifier reads them: unknown claims ignored, `major`
/// 0 when absent, `ent` read leniently ([entitlementsOf]) and `met` too
/// ([metersOf]).
final class LeaseClaims {
  const LeaseClaims({
    this.iss = 'keygrant',
    required this.sub,
    required this.product,
    required this.aid,
    this.fp,
    this.fpk,
    required this.model,
    required this.lim,
    this.major = 0,
    this.minMajor,
    this.upgradeUntil,
    this.ent = const {},
    this.met,
    required this.iat,
    required this.exp,
    this.grace,
    this.test,
  });

  final String iss;

  /// The licence key (`trial:<claim>` on a trial lease).
  final String sub;
  final String product;

  /// The activation id; on a trial lease, the fingerprint's claim hash.
  final String aid;

  /// The device's fingerprint claim hash, when the lease carries one.
  final String? fp;

  /// What [fp] hashes.
  final DeviceKind? fpk;

  /// `perpetual`, `subscription` or `trial`.
  final String model;
  final int lim;

  /// The highest major covered; [openMajor] when open-ended.
  final int major;

  /// The lowest major covered; absent means 1.
  final int? minMajor;

  /// The end of the key's open upgrade window (seconds).
  final int? upgradeUntil;
  final Map<String, Entitlement> ent;

  /// The key's meters, when the lease has the claim.
  final Map<String, MeterClaim>? met;

  /// Signed at and ends at (seconds).
  final int iat;
  final int exp;
  final bool? grace;
  final bool? test;

  /// The claims a lease's payload holds, or null when they do not match (`bad-claims`).
  static LeaseClaims? parse(Object? json) {
    final c = json is List ? null : asObject(json);
    if (c == null || c['iss'] != 'keygrant') return null;
    final sub = _text(c['sub']), product = _text(c['product']), aid = _text(c['aid']);
    final lim = wholeOf(c['lim']), iat = _date(c['iat']), exp = _date(c['exp']);
    final model = c['model'];
    if (sub == null || product == null || aid == null || lim == null || lim <= 0 || iat == null || exp == null) return null;
    if (model != 'perpetual' && model != 'subscription' && model != 'trial') return null;
    final fp = c['fp'];
    if (c.containsKey('fp') && (fp is! String || fp.isEmpty || fp.length > 128)) return null;
    final fpk = DeviceKind.fromWire(c['fpk']);
    if (c.containsKey('fpk') && fpk == null) return null;
    final major = c.containsKey('major') ? _date(c['major']) : 0;
    if (major == null) return null;
    final minMajor = wholeOf(c['minMajor']), upgradeUntil = _date(c['upgradeUntil']);
    if (c.containsKey('minMajor') && (minMajor == null || minMajor <= 0)) return null;
    if (c.containsKey('upgradeUntil') && upgradeUntil == null) return null;
    final grace = c['grace'], test = c['test'];
    if ((c.containsKey('grace') && grace is! bool) || (c.containsKey('test') && test is! bool)) return null;
    return LeaseClaims(
      sub: sub,
      product: product,
      aid: aid,
      fp: fp as String?,
      fpk: fpk,
      model: model as String,
      lim: lim,
      major: major,
      minMajor: minMajor,
      upgradeUntil: upgradeUntil,
      ent: entitlementsOf(c['ent']),
      met: c.containsKey('met') ? metersOf(c['met']) : null,
      iat: iat,
      exp: exp,
      grace: grace as bool?,
      test: test as bool?,
    );
  }

  /// The claims as JSON writes them, absent claims left out.
  Map<String, Object?> toJson() => withoutNulls({
        'iss': iss,
        'sub': sub,
        'product': product,
        'aid': aid,
        'fp': fp,
        'fpk': fpk?.wire,
        'model': model,
        'lim': lim,
        'major': major,
        'minMajor': minMajor,
        'upgradeUntil': upgradeUntil,
        'ent': entitlementsJson(ent),
        'met': met?.map((code, m) => MapEntry(code, m.toJson())),
        'iat': iat,
        'exp': exp,
        'grace': grace,
        'test': test,
      });
}

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

/// A non-negative whole number (a JWT numeric date), or null.
int? _date(Object? value) {
  final whole = wholeOf(value);
  return whole != null && whole >= 0 ? whole : null;
}

/// `met` as a verifier reads it: each member that is an object whose `left`,
/// `total` and `offline` are non-negative whole numbers of at most 2^53 - 1,
/// `resets` true only for JSON true; every other member dropped, and nothing
/// from anything but an object. Never a refusal.
Map<String, MeterClaim> metersOf(Object? raw) {
  final object = raw is List ? null : asObject(raw);
  if (object == null) return const {};
  final kept = <String, MeterClaim>{};
  for (final entry in object.entries) {
    final m = entry.value is List ? null : asObject(entry.value);
    if (m == null) continue;
    final left = figureOf(m['left']), total = figureOf(m['total']), offline = figureOf(m['offline']);
    if (left != null && total != null && offline != null) {
      kept[entry.key] = BaseFigure(left: left, total: total, offline: offline, resets: m['resets'] == true);
    }
  }
  return kept;
}

/// Why a lease did not verify.
enum LeaseFailure {
  malformed('malformed'),
  unknownKey('unknown-key'),
  badSignature('bad-signature'),
  badClaims('bad-claims'),
  expired('expired');

  const LeaseFailure(this.wire);
  final String wire;
}

/// What verifying a lease says: valid with its claims, or why not (an expired
/// lease still with its claims).
final class VerifyResult {
  const VerifyResult.valid(LeaseClaims this.claims) : reason = null;
  const VerifyResult.invalid(LeaseFailure this.reason, [this.claims]);

  final LeaseFailure? reason;
  final LeaseClaims? claims;

  bool get valid => reason == null;

  Map<String, Object?> toJson() =>
      withoutNulls({'valid': valid, 'reason': reason?.wire, 'claims': claims?.toJson()});
}

/// Verify a lease offline against a key set, in the contract's order (2): three
/// parts; a canonical signature; the key the header names (only in the exact
/// form the server writes it), or each key in turn when it names none;
/// Ed25519 over `header.payload` as received; the claims; expiry
/// (`exp * 1000 < now`, so a lease is valid during its `exp` second).
Future<VerifyResult> verifyLease(String token, List<VerifyingKey> keys, int now) async {
  final parts = token.split('.');
  if (parts.length != 3) return const VerifyResult.invalid(LeaseFailure.malformed);
  final [header, payload, signature] = parts;
  final List<int> sig;
  try {
    sig = b64urlDecode(signature);
  } on FormatException {
    return const VerifyResult.invalid(LeaseFailure.malformed);
  }
  final checked = await _signatureCheck(keys, header, sig, utf8.encode('$header.$payload'));
  if (checked != null) return VerifyResult.invalid(checked);
  final claims = LeaseClaims.parse(payloadJson(payload));
  if (claims == null) return const VerifyResult.invalid(LeaseFailure.badClaims);
  if (claims.exp * 1000 < now) return VerifyResult.invalid(LeaseFailure.expired, claims);
  return VerifyResult.valid(claims);
}

/// The signature's verdict: null when one of the set's keys signed it (the key
/// the header names, when it names one).
Future<LeaseFailure?> _signatureCheck(List<VerifyingKey> keys, String header, List<int> sig, List<int> signed) async {
  final kid = namedKeyId(header, _namedHeaderStart);
  final candidates = kid == null ? keys : keys.where((k) => k.kid == kid).toList();
  if (candidates.isEmpty) return LeaseFailure.unknownKey;
  for (final key in candidates) {
    if (await ed25519Verifies(key.key, sig, signed)) return null;
  }
  return LeaseFailure.badSignature;
}

/// A token's payload segment as JSON: canonical base64url of UTF-8 (decoded as
/// WHATWG's TextDecoder does: a leading byte-order mark dropped, an invalid
/// sequence replaced), parsed; a [_NotJson] marker when any step fails.
Object? payloadJson(String payload) {
  try {
    // Dart's decoder drops one leading byte-order mark, as TextDecoder does.
    return jsonDecode(utf8.decode(b64urlDecode(payload), allowMalformed: true));
  } on FormatException {
    return notJson;
  }
}

/// What [payloadJson] answers for a payload that is not JSON: no claims match it.
const Object notJson = _NotJson();

final class _NotJson {
  const _NotJson();
}
