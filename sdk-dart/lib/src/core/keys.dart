/// A product's public keys (the reference's crypto.ts): a JWK checked as every SDK
/// checks one, its id (RFC 7638 thumbprint), the key set a lease is verified
/// against, and the hashes a fingerprint is sent and signed as.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

import 'json.dart';
import 'jws.dart';

/// A configuration the SDK cannot run with (a public key that is not one, both
/// key members given, a denylist that is not a list of texts): thrown when the
/// licence is made, so it is found the first time the app runs.
final class LicenseConfigError extends Error {
  LicenseConfigError(this.message);

  /// What is wrong with the configuration.
  final String message;

  @override
  String toString() => 'KeyGrant: $message';
}

/// One public key of a key set: its raw 32 bytes and its id.
final class VerifyingKey {
  const VerifyingKey(this.kid, this.key);

  /// The key's id (`keyId`), what a lease's header names it by.
  final String kid;

  /// The Ed25519 public key's 32 bytes.
  final Uint8List key;
}

/// A public JWK's raw key, checked as every SDK checks one: an object whose
/// `kty` is "OKP" and `crv` "Ed25519"; no private `d`; `use`, when given,
/// "sig"; `key_ops`, when given, a list naming "verify"; `alg`, when given,
/// "EdDSA" or "Ed25519"; and an `x` that, its trailing `=` dropped, is
/// canonical base64url of 32 bytes. No other member is read. Throws a
/// [LicenseConfigError] otherwise.
Uint8List publicKeyBytes(Object? jwk) {
  final members = asObject(jwk);
  if (members == null || jwk is List) throw LicenseConfigError('not a JWK');
  final refused = _refusalOf(members);
  if (refused != null) throw LicenseConfigError(refused);
  final Uint8List raw;
  try {
    raw = b64urlDecode((members['x'] as String).replaceAll(RegExp(r'=+$'), ''));
  } on FormatException {
    throw LicenseConfigError('its x is not canonical base64url');
  }
  if (raw.length != 32) throw LicenseConfigError('an Ed25519 public key is 32 bytes');
  return raw;
}

String? _refusalOf(Map<String, Object?> m) {
  if (m['kty'] != 'OKP' || m['crv'] != 'Ed25519') return 'not an Ed25519 key (kty OKP, crv Ed25519)';
  if (m.containsKey('d')) return 'this JWK holds a private key: embed the public one';
  if (m.containsKey('use') && m['use'] != 'sig') return 'its use is not sig';
  if (m.containsKey('key_ops') && !_namesVerify(m['key_ops'])) return 'its key_ops do not include verify';
  if (m.containsKey('alg') && m['alg'] != 'EdDSA' && m['alg'] != 'Ed25519') return 'its alg is not EdDSA';
  return m['x'] is String ? null : 'it has no x';
}

bool _namesVerify(Object? ops) => ops is List && ops.contains('verify');

/// A public key's id, the `kid` a lease's header names it by: its RFC 7638
/// thumbprint, the base64url (no padding) of the SHA-256 of
/// `{"crv":"Ed25519","kty":"OKP","x":"<x>"}`, `x` written canonically. A `kid`
/// member a JWK carries is not read. Throws for a JWK that is not an Ed25519
/// public key.
String keyId(Object? jwk) {
  final members = '{"crv":"Ed25519","kty":"OKP","x":"${b64urlEncode(publicKeyBytes(jwk))}"}';
  return b64urlEncode(hash.sha256.convert(utf8.encode(members)).bytes);
}

/// A key set: each public JWK with its id, in the order given, a key given
/// twice kept once. Throws for an empty set or a JWK that is not an Ed25519
/// public key.
List<VerifyingKey> importVerifyingKeys(List<Object?> jwks) {
  if (jwks.isEmpty) throw LicenseConfigError('a key set holds at least one public key');
  final keys = <VerifyingKey>[];
  for (final jwk in jwks) {
    final kid = keyId(jwk);
    if (!keys.any((k) => k.kid == kid)) keys.add(VerifyingKey(kid, publicKeyBytes(jwk)));
  }
  return keys;
}

/// Lowercase hex SHA-256 of the UTF-8 of `text`.
String sha256Hex(String text) => hash.sha256.convert(utf8.encode(text)).toString();

/// The `fp` claim for a device fingerprint: hex SHA-256 of it, namespaced. The
/// server signs it into a licence lease; the SDK computes it for the device it
/// runs on and compares, so the lease never carries the fingerprint itself.
String fingerprintClaim(String fingerprint) => sha256Hex('keygrant-fp|$fingerprint');

/// A machine's fingerprint from what identifies it, hashed so the raw
/// identifier never leaves it.
String hashFingerprint(String raw) => sha256Hex('keygrant|$raw');

/// The keys of a key set given as JSON text, as `/pubkey` answers it
/// (`{"keys":[...]}`, or that whole answer), a list of JWKs, or one JWK, for
/// [LicenseConfig.publicJwks]. An object whose `keys` member is not a list is
/// refused, never read as one JWK. Throws a [LicenseConfigError] for text that
/// is none of these.
List<Map<String, Object?>> parseJwkSet(String json) {
  final Object? parsed;
  try {
    parsed = jsonDecode(json);
  } on FormatException {
    throw LicenseConfigError('the key set is not JSON');
  }
  if (parsed is List) return [for (final key in parsed) _jwkOf(key)];
  final object = asObject(parsed);
  if (object == null) throw LicenseConfigError('the key set is not a JWK, a list of JWKs or a JWK set');
  if (!object.containsKey('keys')) return [object];
  final keys = object['keys'];
  if (keys is! List) throw LicenseConfigError('the key set\'s keys is not a list');
  return [for (final key in keys) _jwkOf(key)];
}

Map<String, Object?> _jwkOf(Object? key) {
  final object = asObject(key);
  if (object == null) throw LicenseConfigError('a key of the set is not a JWK');
  return object;
}
