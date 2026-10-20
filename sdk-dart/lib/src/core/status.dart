/// What `status()` answers (the SDK contract, 5.2, 5.8, 10.6 and 12.8).
library;

import 'entitlements.dart';
import 'json.dart';
import 'meter_types.dart';
import 'types.dart';

/// Who a licence file is licensed to: a name, an email address, or both.
final class LicensedTo {
  const LicensedTo({this.name, this.email});

  final String? name;
  final String? email;

  Map<String, Object?> toJson() => withoutNulls({'name': name, 'email': email});

  @override
  bool operator ==(Object other) => other is LicensedTo && other.name == name && other.email == email;

  @override
  int get hashCode => Object.hash(name, email);

  @override
  String toString() => [if (name != null) name!, if (email != null) '<$email>'].join(' ');
}

/// The licence's status. Compared by content: an app comparing two statuses
/// sees no change from a lease that grants nothing.
final class LicenseStatus {
  const LicenseStatus(
    this.state, {
    this.reason,
    this.key,
    this.trialDaysLeft,
    this.trialEndsAt,
    this.test = false,
    this.entitlements = const {},
    this.meters = const {},
    this.source,
    this.licensedTo,
    this.stalled = false,
  });

  final LicenseState state;
  final LicenseReason? reason;

  /// The licence key this device holds, when it holds one. On a file status
  /// that is `licensed`, or `invalid` with `revoked-file`, `upgrade` or
  /// `outdated`, the key the file records.
  final String? key;
  final int? trialDaysLeft;

  /// When the trial ends (ms since the epoch): the end its lease was signed to.
  final int? trialEndsAt;

  /// True on a TEST licence (one the developer made to exercise the app).
  final bool test;

  /// What the licence grants beyond the base product, as its lease signs them:
  /// on a `licensed` status from the licence's lease or file, on a `trial`
  /// status from the trial's lease; empty on every other status.
  final Map<String, Entitlement> entitlements;

  /// The key's meters, net of this device's unsynced spends: on a `licensed`
  /// status from a key's lease only; empty otherwise.
  final Map<String, MeterStatus> meters;

  /// [LicenseSource.file] when the status rests on a stored offline licence file.
  final LicenseSource? source;

  /// Who the stored offline licence file is licensed to.
  final LicensedTo? licensedTo;

  /// True when an earlier call on this licence has not finished, so this
  /// answer comes from what is stored, with no ask and no write.
  final bool stalled;

  /// This status, saying it was answered behind a call that has not finished.
  LicenseStatus asStalled() => _copy(stalled: true);

  /// This status with `meters`.
  LicenseStatus withMeters(Map<String, MeterStatus> meters) => _copy(meters: meters);

  LicenseStatus _copy({bool? stalled, Map<String, MeterStatus>? meters}) => LicenseStatus(
        state,
        reason: reason,
        key: key,
        trialDaysLeft: trialDaysLeft,
        trialEndsAt: trialEndsAt,
        test: test,
        entitlements: entitlements,
        meters: meters ?? this.meters,
        source: source,
        licensedTo: licensedTo,
        stalled: stalled ?? this.stalled,
      );

  /// The status as the reference's JSON writes it: a member with no value,
  /// `test` and `stalled` when false, and empty entitlements and meters left out.
  Map<String, Object?> toJson() => withoutNulls({
        'state': state.wire,
        'reason': reason?.wire,
        'key': key,
        'trialDaysLeft': trialDaysLeft,
        'trialEndsAt': trialEndsAt,
        'test': test ? true : null,
        'entitlements': entitlements.isEmpty ? null : entitlementsJson(entitlements),
        'meters': meters.isEmpty ? null : meters.map((code, m) => MapEntry(code, m.toJson())),
        'source': source?.wire,
        'licensedTo': licensedTo?.toJson(),
        'stalled': stalled ? true : null,
      });

  @override
  bool operator ==(Object other) =>
      other is LicenseStatus &&
      other.state == state &&
      other.reason == reason &&
      other.key == key &&
      other.trialDaysLeft == trialDaysLeft &&
      other.trialEndsAt == trialEndsAt &&
      other.test == test &&
      _sameMap(other.entitlements, entitlements) &&
      _sameMap(other.meters, meters) &&
      other.source == source &&
      other.licensedTo == licensedTo &&
      other.stalled == stalled;

  @override
  int get hashCode => Object.hash(state, reason, key, trialDaysLeft, trialEndsAt, test, entitlements.length,
      meters.length, source, licensedTo, stalled);

  @override
  String toString() => 'LicenseStatus(${toJson()})';
}

bool _sameMap<V>(Map<String, V> a, Map<String, V> b) =>
    a.length == b.length && a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);
