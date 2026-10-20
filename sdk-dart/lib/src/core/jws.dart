/// The compact JWS core a lease and a licence file share (the reference's jws.ts):
/// canonical base64url, the form of a key id, the key id a header names
/// (matched as bytes), and Ed25519 verification.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// An id of the form a key id takes: 1 to 64 characters of the base64url
/// alphabet (a thumbprint is 43). A licence file's id (`fid`) takes the same form.
final RegExp kidPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

final RegExp _alphabet = RegExp(r'^[A-Za-z0-9_-]*$');

/// `bytes` as base64url, no padding.
String b64urlEncode(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Decode CANONICAL base64url: the URL-safe alphabet, no padding, and nothing
/// the encoder above would not have written (encoding the result gives the
/// input back). Anything else throws a [FormatException].
Uint8List b64urlDecode(String input) {
  if (!_alphabet.hasMatch(input) || input.length % 4 == 1) {
    throw const FormatException('not base64url');
  }
  final pad = input.length % 4 == 0 ? 0 : 4 - input.length % 4;
  final bytes = base64Url.decode(input + '=' * pad);
  if (b64urlEncode(bytes) != input) throw const FormatException('not canonical base64url');
  return bytes;
}

/// The key id a header names when it is, byte for byte, canonical base64url of
/// `<start><kid>"}`, `<kid>` of the form [kidPattern]; null for any other
/// header. Matched as bytes, never parsed: each byte is one character, so a
/// byte past ASCII matches nothing.
String? namedKeyId(String header, String start) {
  final Uint8List bytes;
  try {
    bytes = b64urlDecode(header);
  } on FormatException {
    return null;
  }
  final text = String.fromCharCodes(bytes);
  if (!text.startsWith(start) || !text.endsWith('"}')) return null;
  if (text.length < start.length + 2) return null;
  final kid = text.substring(start.length, text.length - 2);
  return kidPattern.hasMatch(kid) ? kid : null;
}

final Ed25519 _ed25519 = Ed25519();

/// Whether `signature` is the Ed25519 signature of `key` (32 raw bytes) over
/// `message`. A signature of any length but 64 bytes, a key that is no point
/// on the curve, and a verifier that throws are no signature: this never throws.
Future<bool> ed25519Verifies(List<int> key, List<int> signature, List<int> message) async {
  if (signature.length != 64 || key.length != 32) return false;
  try {
    final publicKey = SimplePublicKey(key, type: KeyPairType.ed25519);
    return await _ed25519.verify(message, signature: Signature(signature, publicKey: publicKey));
  } catch (_) {
    return false;
  }
}
