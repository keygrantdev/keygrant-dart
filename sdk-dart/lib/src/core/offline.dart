/// What the SDK decides from what the device holds, without asking the server
/// (the SDK contract, 5.1 to 5.5; offline.ts): whether a lease licenses this
/// build, what a trial shows, which refusal still stands, and when to ask again.
library;

import 'device.dart';
import 'entitlements.dart';
import 'lease.dart';
import 'status.dart';
import 'stored_state.dart';
import 'types.dart';
import 'wire.dart';

const int _dayMs = 86400000;

/// How long after the server answered without a lease before asking again (ms).
const int askAgainMs = 3600000;

/// How long after an ask that got no answer at all before asking again (ms).
const int retryUnansweredMs = 60000;

/// How often, at most, a running trial reports its launch (ms).
const int trialReportMs = _dayMs;

/// A valid lease is renewed early once less than this is left (or half its life).
const int renewWithinMs = 7 * _dayMs;

/// The major a build runs as: the configured one read as the server reads a
/// version (0.x as 1, and majors from 1 up); absent is 1.
int majorOf(int? configured) {
  final major = configured ?? 1;
  return major < 1 ? 1 : major;
}

/// Why a lease does not license this build ([checkLease]).
enum CheckFailure {
  expired('expired'),
  upgrade('upgrade'),
  outdated('outdated'),
  tampered('tampered'),
  unknownKey('unknown-key'),
  device('device');

  const CheckFailure(this.wire);
  final String wire;

  /// The status reason it gives (an expired lease is `offline`).
  LicenseReason get reason => switch (this) {
        CheckFailure.expired => LicenseReason.offline,
        CheckFailure.upgrade => LicenseReason.upgrade,
        CheckFailure.outdated => LicenseReason.outdated,
        CheckFailure.tampered => LicenseReason.tampered,
        CheckFailure.unknownKey => LicenseReason.unknownKey,
        CheckFailure.device => LicenseReason.device,
      };
}

/// What a lease says about this build, offline: licensed with its claims, or why not.
final class LeaseCheck {
  const LeaseCheck.ok(LeaseClaims this.claims) : failure = null;
  const LeaseCheck.failed(CheckFailure this.failure) : claims = null;

  final CheckFailure? failure;
  final LeaseClaims? claims;

  /// Whether the lease is a test licence's.
  bool get test => claims?.test == true;

  bool get ok => failure == null;

  Map<String, Object?> toJson() => ok ? {'ok': true, 'test': test} : {'ok': false, 'reason': failure!.wire};
}

/// Whose a licence lease must be: the key and activation stored, and this device.
final class LeaseHolder {
  const LeaseHolder({required this.key, required this.activationId, required this.claims, required this.canTell});

  final String key;
  final String activationId;
  final List<String> claims;
  final bool canTell;
}

/// A verified licence lease held to this product, holder and build (5.1).
LeaseCheck checkLease(VerifyResult v, String product, int major, LeaseHolder holder) {
  final claims = v.claims;
  if (!v.valid || claims == null) {
    return LeaseCheck.failed(switch (v.reason) {
      LeaseFailure.expired => CheckFailure.expired,
      LeaseFailure.unknownKey => CheckFailure.unknownKey,
      _ => CheckFailure.tampered,
    });
  }
  if (claims.product != product || !sameKey(claims.sub, holder.key) || claims.aid != holder.activationId) {
    return const LeaseCheck.failed(CheckFailure.tampered);
  }
  if (_heldToAnother(claims, holder.claims, holder.canTell)) return const LeaseCheck.failed(CheckFailure.device);
  if (major < (claims.minMajor ?? 1)) return const LeaseCheck.failed(CheckFailure.outdated);
  if (major > claims.major) return const LeaseCheck.failed(CheckFailure.upgrade);
  return LeaseCheck.ok(claims);
}

bool _heldToAnother(LeaseClaims claims, List<String> deviceClaims, bool canTell) {
  final fp = claims.fp;
  if (fp == null || claims.fpk != DeviceKind.machine || !canTell) return false;
  return !deviceClaims.contains(fp);
}

/// The status a stored licence lease gives when the server gives no verdict
/// on it (5.1): licensed with `test` and its entitlements; `expired` /
/// `offline` with the key; `invalid` with the reason and the key; `invalid` /
/// `tampered` with no key.
LicenseStatus leaseStatus(LeaseCheck check, String? key) {
  final claims = check.claims;
  if (claims != null) {
    return LicenseStatus(LicenseState.licensed, key: key, test: check.test, entitlements: claims.ent);
  }
  return switch (check.failure!) {
    CheckFailure.expired => LicenseStatus(LicenseState.expired, reason: LicenseReason.offline, key: key),
    CheckFailure.tampered => const LicenseStatus(LicenseState.invalid, reason: LicenseReason.tampered),
    final failure => LicenseStatus(LicenseState.invalid, reason: failure.reason, key: key),
  };
}

/// Whether a licence lease whose signature holds (expired or not) is held to
/// a machine this run can tell is not this device.
bool heldElsewhere(VerifyResult v, Device device) {
  final claims = v.valid || v.reason == LeaseFailure.expired ? v.claims : null;
  return claims != null && _heldToAnother(claims, device.claims, device.canTell);
}

/// `kept` after running `major` on a lease with these claims at `now`: raised
/// to it while the lease's upgrade window is open, else as it was.
int? keptWith(int? kept, LeaseClaims claims, int now, int major) {
  final until = claims.upgradeUntil;
  if (until == null || now >= until * 1000) return kept;
  return (kept ?? 0) > major ? kept : major;
}

/// A trial lease, verified: a trial's, for this product, and for this device
/// (judged only when started under a machine id and this run can tell).
bool trialLeaseValid(VerifyResult v, String product, List<String> deviceClaims, bool canTell) {
  final claims = v.claims;
  if (!v.valid || claims == null || claims.model != 'trial' || claims.product != product) return false;
  return claims.fpk != DeviceKind.machine || !canTell || deviceClaims.contains(claims.aid);
}

/// What a trial's status reads of its trial lease: whether it is valid here,
/// and when it is, the end it was signed to (ms) and its entitlements.
final class TrialLease {
  const TrialLease.invalid()
      : valid = false,
        endsAt = null,
        entitlements = const {};
  const TrialLease.valid(int this.endsAt, this.entitlements) : valid = true;

  final bool valid;
  final int? endsAt;
  final Map<String, Entitlement> entitlements;
}

TrialLease trialLeaseOf(VerifyResult v, String product, List<String> deviceClaims, bool canTell) {
  if (!trialLeaseValid(v, product, deviceClaims, canTell)) return const TrialLease.invalid();
  return TrialLease.valid(v.claims!.exp * 1000, v.claims!.ent);
}

/// A trial's status (5.4): unlicensed with no trial evidence; running only
/// while its lease is valid, with the end that lease was signed to (the stored
/// one only when the lease's is not known); else expired.
LicenseStatus trialStatusOf(StoredState state, int now, bool leaseValid,
    [int? leaseEndsAt, Map<String, Entitlement> leaseEntitlements = const {}]) {
  if (state.trialStart == null && state.trialEndsAt == null && state.trialLease == null) {
    return const LicenseStatus(LicenseState.unlicensed);
  }
  if (!leaseValid) return const LicenseStatus(LicenseState.expired, reason: LicenseReason.trial);
  final endsAt = leaseEndsAt ?? state.trialEndsAt;
  final daysLeft = endsAt == null ? null : _daysLeft(endsAt, now);
  return LicenseStatus(LicenseState.trial, trialEndsAt: endsAt, trialDaysLeft: daysLeft, entitlements: leaseEntitlements);
}

int _daysLeft(int endsAt, int now) {
  final days = ((endsAt - now) / _dayMs).ceil();
  return days < 0 ? 0 : days;
}

/// What storing the server's refusal changes: `revoked` drops the lease;
/// `upgrade` and `outdated` keep it with the major refused; `device` keeps it
/// with the device's own claim.
StatePatch refusalPatch(Refusal refused, int major, String? ownClaim) => switch (refused) {
      Refusal.revoked => {Field.lease: null, Field.refused: refused.wire, Field.refusedMajor: null, Field.refusedFor: null},
      Refusal.device => {
          Field.refused: refused.wire,
          Field.refusedMajor: null,
          Field.refusedFor: [if (ownClaim != null) ownClaim],
        },
      _ => {Field.refused: refused.wire, Field.refusedMajor: major, Field.refusedFor: null},
    };

/// What a check-in with this device writes of the install's key.
StatePatch keyedBy(DeviceKind? kind) => kind == DeviceKind.machine ? {Field.deviceKind: 'machine'} : const {};

/// What a new lease from the server clears: any refusal, and the wait.
const StatePatch leased = {
  Field.refused: null,
  Field.refusedMajor: null,
  Field.refusedFor: null,
  Field.backoffSince: null,
  Field.backoffMs: null,
};

/// What a deactivated device keeps of its licence: nothing but its trial
/// evidence and clock guard.
const StatePatch unkeyed = {
  Field.key: null,
  Field.activationId: null,
  Field.lease: null,
  Field.checkedMajor: null,
  Field.keptMajor: null,
  Field.deviceKind: null,
  ...leased,
};

/// What an activation saves: the key, activation, lease, major heard, kept
/// major, refusal and wait cleared, and what the install is keyed by.
StatePatch activationPatch({
  required String key,
  required String activationId,
  required String lease,
  required LeaseClaims claims,
  required int now,
  required int major,
  required DeviceKind? kind,
}) =>
    {
      Field.key: key,
      Field.activationId: activationId,
      Field.lease: lease,
      Field.checkedMajor: major,
      Field.keptMajor: keptWith(null, claims, now, major),
      ...leased,
      Field.deviceKind: kind?.wire,
    };

/// The stored refusal that still stands for a build running `major`, or null
/// (5.3). `device` (when given) is who this run is: a device refusal with
/// `refusedFor` stands only while this run can tell and its own claim is in it.
Refusal? standingRefusal(StoredState state, int major, {String? ownClaim, bool canTell = false}) {
  final refused = state.refused, refusedMajor = state.refusedMajor, refusedFor = state.refusedFor;
  if (refused == null) return null;
  if (refused == Refusal.device && refusedFor != null) {
    final own = canTell ? ownClaim : null;
    return own != null && refusedFor.contains(own) ? refused : null;
  }
  if (refused == Refusal.revoked || refused == Refusal.device || refusedMajor == null) return refused;
  final stands = refused == Refusal.upgrade ? major >= refusedMajor : major <= refusedMajor;
  return stands ? refused : null;
}

/// Whether to ask the server now: forced, no wait recorded, the device clock
/// before the recorded ask, or the wait over.
bool askDue(StoredState state, int clockNow, bool force) {
  final since = state.backoffSince;
  if (force || since == null || clockNow < since) return true;
  return clockNow - since >= (state.backoffMs ?? askAgainMs);
}

/// Whether a valid lease is near enough its end at `now` to renew it early.
bool renewsEarly(LeaseClaims claims, int now) {
  final left = claims.exp * 1000 - now;
  final life = (claims.exp - claims.iat) * 1000;
  final within = life / 2 < renewWithinMs ? life / 2 : renewWithinMs;
  return left < within;
}

/// Whether a running trial reports its launch at `now` (the guarded clock):
/// neither its last trial answer (`trialAt`) nor its last report
/// (`trialReportedAt`) is within [trialReportMs] before `now`; a stamp ahead of
/// `now` is.
bool trialReportDue(StoredState state, int now) {
  bool recent(int? at) => at != null && now - at < trialReportMs;
  return !recent(state.trialAt) && !recent(state.trialReportedAt);
}
