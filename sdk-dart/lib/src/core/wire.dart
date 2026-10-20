/// What the SDK sends and reads on the wire (the SDK contract, sections 3 and
/// 11; wire.ts), and the small pieces of it that need no engine state.
library;

import 'json.dart';
import 'text.dart';
import 'types.dart';

/// What the activate endpoint accepts for a device name; longer is cut.
const int maxDeviceName = 120;

/// The longest licence key it accepts (UTF-16 units).
const int maxKey = 120;

/// The longest address the endpoint takes; a longer one is no key's address.
const int maxEmail = 254;

/// How long a check `status()` makes on a valid lease may hold it up (ms).
const int statusCheckTimeoutMs = 5000;

/// The SDK error a refused activation's error word is.
LicenseError mapServerError(Object? error) => switch (error) {
      'invalid-key' => LicenseError.invalidKey,
      'limit' => LicenseError.limit,
      'revoked' || 'expired' => LicenseError.revoked,
      'upgrade-required' => LicenseError.upgrade,
      'update-required' => LicenseError.outdated,
      'user-email-required' => LicenseError.userEmailRequired,
      'user-email-mismatch' => LicenseError.userEmailMismatch,
      'user-code-required' => LicenseError.userCodeRequired,
      'user-code-invalid' => LicenseError.userCodeInvalid,
      'too-many-codes' => LicenseError.tooManyCodes,
      'too-many-attempts' => LicenseError.tooManyAttempts,
      'try-again' => LicenseError.tryAgain,
      _ => LicenseError.network,
    };

/// The definitive refusal a validate's error is, or null for any other error,
/// which is never taken as a verdict.
Refusal? refusalOf(Object? error) => switch (error) {
      'upgrade-required' => Refusal.upgrade,
      'update-required' => Refusal.outdated,
      'revoked' || 'expired' || 'deactivated' => Refusal.revoked,
      'device' => Refusal.device,
      _ => null,
    };

/// Whether a response is no answer at all: an outage (5xx) or a refusal to serve now (429).
bool noAnswer(int status) => status >= 500 || status == 429;

/// The key a person entered, trimmed and upper-cased (what is sent and stored),
/// or null when it cannot be a key: empty, or longer than [maxKey].
String? enteredKey(String key) {
  final entered = jsTrim(key).toUpperCase();
  return entered.isNotEmpty && entered.length <= maxKey ? entered : null;
}

/// An address a person typed, trimmed: [send] null for none (a blank is none),
/// [tooLong] for one longer than [maxEmail], which can be no key's address.
final class EnteredEmail {
  const EnteredEmail._(this.send, this.tooLong);
  final String? send;
  final bool tooLong;
}

EnteredEmail enteredEmail(String? email) {
  final entered = jsTrim(email ?? '');
  if (entered.isEmpty) return const EnteredEmail._(null, false);
  return entered.length <= maxEmail ? EnteredEmail._(entered, false) : const EnteredEmail._(null, true);
}

final RegExp _digits = RegExp(r'^[0-9]{6}$');

/// A code a person typed: its ends trimmed, then its spaces (U+0020) dropped.
/// [send] null for none (a blank is none); [malformed] when it is not exactly
/// six ASCII digits.
final class EnteredCode {
  const EnteredCode._(this.send, this.malformed);
  final String? send;
  final bool malformed;
}

EnteredCode enteredCode(String? code) {
  final entered = jsTrim(code ?? '').replaceAll(' ', '');
  if (entered.isEmpty) return const EnteredCode._(null, false);
  return _digits.hasMatch(entered) ? EnteredCode._(entered, false) : const EnteredCode._(null, true);
}

/// What an activation sends for what a person typed for a user-locked key, or
/// the error that refuses it before anything is sent.
final class Typed {
  const Typed._({this.email, this.code, this.refused});

  final String? email;
  final String? code;
  final LicenseError? refused;

  /// The members an activation's body carries: each only when there is one.
  Map<String, Object?> get send => withoutNulls({'email': email, 'code': code});
}

/// `typedFor`: an address longer than any is `user-email-mismatch`, a code that
/// is not six digits `user-code-invalid`; the address is judged first.
Typed typedFor({String? email, String? code}) {
  final address = enteredEmail(email);
  if (address.tooLong) return const Typed._(refused: LicenseError.userEmailMismatch);
  final typed = enteredCode(code);
  if (typed.malformed) return const Typed._(refused: LicenseError.userCodeInvalid);
  return Typed._(email: address.send, code: typed.send);
}

/// Whether two licence keys are the same key: matched without regard to case.
bool sameKey(String a, String b) => a.toUpperCase() == b.toUpperCase();

/// The `error` member of a body, or null.
Object? errorOf(Object? json) => json is List ? null : asObject(json)?['error'];

/// A server body's `lease` and `activationId`, text only.
({String? lease, String? activationId}) parseLeaseBody(Object? json) {
  final b = json is List ? null : asObject(json);
  final lease = b?['lease'], activationId = b?['activationId'];
  return (lease: lease is String ? lease : null, activationId: activationId is String ? activationId : null);
}

/// The (unsigned) trial answer, or null when it is not one: numeric
/// `trialStart` and `trialEndsAt`, and a text `lease` when there is one.
({num trialStart, num trialEndsAt, String? lease})? parseTrialBody(Object? json) {
  final b = json is List ? null : asObject(json);
  final start = b?['trialStart'], end = b?['trialEndsAt'], lease = b?['lease'];
  if (start is! num || end is! num) return null;
  return (trialStart: start, trialEndsAt: end, lease: lease is String ? lease : null);
}

/// The smallest of the times given, or null when none is.
T? earliest<T extends num>(Iterable<T?> values) {
  T? least;
  for (final value in values) {
    if (value != null && (least == null || value < least)) least = value;
  }
  return least;
}
