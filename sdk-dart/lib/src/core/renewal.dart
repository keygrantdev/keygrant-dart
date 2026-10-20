/// The online validate, decided without I/O (the SDK contract, 5.2 and 5.3;
/// renewal.ts): when `status()` asks on a lease that licenses this build, and
/// what an ask's answer saves and says.
library;

import 'http.dart';
import 'lease.dart';
import 'meters.dart';
import 'offline.dart';
import 'status.dart';
import 'stored_state.dart';
import 'types.dart';
import 'wire.dart';

/// What an ask's answer does: whether the server answered at all, the status
/// it gives (null: the caller's own answer stands), and what is saved.
final class RenewalOutcome {
  const RenewalOutcome({required this.answered, required this.status, required this.patch});

  final bool answered;
  final LicenseStatus? status;
  final StatePatch patch;
}

/// What a validate's answer saves and says (the 5.3 table). `check` is the
/// offline check of the lease a 200 carried (null when it carried none),
/// `askedAt` the device clock when it was asked, `now` the time the lease was
/// judged at, `kind` and `ownClaim` who this device is as the ask read it.
RenewalOutcome renewalOutcome({
  required HttpResponse? response,
  LeaseCheck? check,
  required int askedAt,
  required int now,
  required int major,
  required String? key,
  required int? keptMajor,
  required DeviceKind? kind,
  required String? ownClaim,
}) {
  final keyed = keyedBy(kind);
  if (response == null) {
    return RenewalOutcome(
      answered: false,
      status: null,
      patch: {Field.backoffSince: askedAt, Field.backoffMs: retryUnansweredMs, ...keyed},
    );
  }
  final backoff = {Field.backoffSince: askedAt, Field.backoffMs: askAgainMs, ...keyed};
  if (noAnswer(response.status)) return RenewalOutcome(answered: false, status: null, patch: backoff);
  if (response.status == 200) {
    return _leaseOutcome(response, check, backoff, major: major, key: key, keptMajor: keptMajor, now: now, kind: kind);
  }
  final refused = refusalOf(errorOf(response.json));
  return RenewalOutcome(
    answered: true,
    status: refused == null ? null : LicenseStatus(LicenseState.invalid, reason: refused.reason, key: key),
    patch: {Field.checkedMajor: major, ...backoff, if (refused != null) ...refusalPatch(refused, major, ownClaim)},
  );
}

RenewalOutcome _leaseOutcome(
  HttpResponse response,
  LeaseCheck? check,
  StatePatch backoff, {
  required int major,
  required String? key,
  required int? keptMajor,
  required int now,
  required DeviceKind? kind,
}) {
  final lease = parseLeaseBody(response.json).lease;
  if (lease == null || lease.isEmpty || check == null || !_standsBehind(check)) {
    return RenewalOutcome(answered: true, status: null, patch: {Field.checkedMajor: major, ...backoff});
  }
  final status = leaseStatus(check, key);
  final claims = check.claims;
  final patch = <String, Object?>{
    Field.lease: lease,
    Field.checkedMajor: major,
    if (claims != null) Field.keptMajor: keptWith(keptMajor, claims, now, major),
    ...leased,
    ...keyedBy(kind),
  };
  return RenewalOutcome(answered: true, status: status, patch: patch);
}

/// Whether the server stands behind a checked lease: it licenses this build,
/// or it is for another build or device.
bool _standsBehind(LeaseCheck check) =>
    check.ok || check.failure == CheckFailure.upgrade || check.failure == CheckFailure.outdated || check.failure == CheckFailure.device;

/// Whether `status()`, holding a lease that licenses this build, asks the
/// server now (5.2): a newer major than the server last heard on an open
/// lease, a lease nearing its end, or a journal to report whose wait is not
/// running; and only when [askDue] allows.
bool asksOnValidLease({
  required LeaseClaims claims,
  required StoredState state,
  required int major,
  required int now,
  required int clockNow,
}) {
  final newMajor = claims.major >= openMajor && major > (state.checkedMajor ?? 0);
  final due = newMajor || renewsEarly(claims, now) || journalAsks(state.spends, now);
  return due && askDue(state, clockNow, false);
}
