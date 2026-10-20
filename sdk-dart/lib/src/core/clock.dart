/// The clock guard (the SDK contract, 5.6; clock.ts), decided without I/O.
library;

import 'wire.dart';

/// How far the clock guard may run ahead of a fresh lease's signing time
/// before it is brought back (ms).
const int clockToleranceMs = 3600000;

/// Now, by the clock guard: never earlier than the latest time the device has
/// seen, so a clock put back cannot bring an expired lease back.
int guardedNow(int clockNow, int? lastSeen) => clockNow > (lastSeen ?? 0) ? clockNow : (lastSeen ?? 0);

/// A fresh lease's claims as the clock guard reads them.
final class SignedAt {
  const SignedAt({required this.sub, required this.aid, required this.iat});

  final String sub;
  final String aid;

  /// Seconds.
  final int iat;
}

/// Where the clock guard is brought back to on a lease the server has just
/// signed, or null to leave it: only a lease for THIS key (without case) and
/// activation, no older than the one held, when the guard is MORE than
/// [clockToleranceMs] past its `iat`; then to the device clock, never below `iat`.
int? clockCorrection({
  required int clockNow,
  required int? lastSeen,
  required SignedAt? claims,
  required int? heldIat,
  required String key,
  required String activationId,
}) {
  if (claims == null || !sameKey(claims.sub, key) || claims.aid != activationId) return null;
  if ((lastSeen ?? 0) - claims.iat * 1000 <= clockToleranceMs) return null;
  if (heldIat != null && claims.iat < heldIat) return null;
  final signed = claims.iat * 1000;
  return clockNow > signed ? clockNow : signed;
}

/// The latest time seen that a save writes: the guard brought back exactly as
/// given when the save carries one, else never earlier than what is stored nor
/// than the device clock.
int savedLastSeen(int? stored, int clockNow, int? guard) {
  if (guard != null) return guard;
  return (stored ?? 0) > clockNow ? stored! : clockNow;
}
