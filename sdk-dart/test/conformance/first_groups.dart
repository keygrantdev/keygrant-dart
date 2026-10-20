// The first groups of the file, answered as the reference's replay.ts answers them.

import 'dart:convert';
import 'dart:typed_data';

import 'package:keygrant/src/core/clock.dart';
import 'package:keygrant/src/core/entitlements.dart';
import 'package:keygrant/src/core/identity.dart';
import 'package:keygrant/src/core/keys.dart';
import 'package:keygrant/src/core/lease.dart';
import 'package:keygrant/src/core/merge.dart';
import 'package:keygrant/src/core/offline.dart';
import 'package:keygrant/src/core/text.dart';
import 'package:keygrant/src/core/types.dart';
import 'package:keygrant/src/core/wire.dart';

import 'harness.dart';
import 'inputs.dart';

/// The groups that judge a lease or a trial, and what they read of a device.
void leaseGroups() {
  conformanceGroup('leases', (v) async {
    final verified = await verifyLease(v['token'] as String, fileKeys(), intOr(v['now'])!);
    final check = checkLease(verified, v['product'] as String, intOr(v['major'])!, holderOf(v['holder']));
    return {'verify': verified.toJson(), 'expect': check.toJson()};
  });
  conformanceGroup('trials', (v) async {
    final verified = await verifyLease(v['token'] as String, fileKeys(), intOr(v['now'])!);
    final device = deviceOf(v['device']);
    return {'expect': trialLeaseValid(verified, v['product'] as String, device.claims, device.canTell)};
  });
  conformanceGroup('fingerprintClaims', (v) => {'claim': fingerprintClaim(v['input'] as String)});
  conformanceGroup('fingerprints', (v) => {'fingerprint': hashFingerprint(v['raw'] as String)});
  conformanceGroup('machineFingerprints', (v) => {'fingerprint': machineFingerprint(v['id'] as String)});
  conformanceGroup('hostFingerprints',
      (v) => {'fingerprint': hostFingerprint(v['host'] as String, v['platform'] as String, v['arch'] as String)});
  conformanceGroup('kept', (v) {
    final claims = baseClaims(upgradeUntil: intOr(v['upgradeUntil']));
    return {'expect': keptWith(intOr(v['kept']), claims, intOr(v['now'])!, intOr(v['major'])!)};
  });
  conformanceGroup('renew', (v) {
    final claims = baseClaims(iat: intOr(v['iat']), exp: intOr(v['exp']));
    return {'expect': renewsEarly(claims, intOr(v['now'])!)};
  });
  conformanceGroup('asks', (v) => {'expect': askDue(stateOf(v['state']), intOr(v['clockNow'])!, v['force'] as bool)});
  conformanceGroup('standing', (v) {
    final given = v['device'] == null ? null : deviceOf(v['device']);
    final refusal = standingRefusal(stateOf(v['state']), intOr(v['major'])!,
        ownClaim: given?.ownClaim, canTell: given?.canTell ?? false);
    return {'expect': refusal?.wire};
  });
  conformanceGroup('trialStatuses', (v) {
    final status = trialStatusOf(stateOf(v['state']), intOr(v['now'])!, v['leaseValid'] as bool, intOr(v['leaseEndsAt']));
    return {'expect': status.toJson()};
  });
}

/// The groups that pin a patch, a merge or the clock guard.
void patchGroups() {
  conformanceGroup('refusalPatches', (v) {
    final refused = Refusal.fromWire(v['refused'])!;
    return {'expect': refusalPatch(refused, intOr(v['major'])!, deviceOf(v['device']).ownClaim)};
  });
  conformanceGroup('leasePatches', (v) => {'expect': v['patch'] == 'LEASED' ? leased : unkeyed});
  conformanceGroup('keyedBy', (v) => {'expect': keyedBy(DeviceKind.fromWire(v['kind']))});
  conformanceGroup('merges', (v) {
    final state = merged(stateOf(v['latest']), (v['patch'] as Map<String, Object?>), basisOf(v['basis']));
    return {'expect': state.toJson()};
  });
  conformanceGroup('guardedNow', (v) => {'expect': guardedNow(intOr(v['clockNow'])!, intOr(v['lastSeen']))});
  conformanceGroup('clockCorrections', (v) {
    final c = v['claims'] as Map<String, Object?>?;
    final claims = c == null ? null : SignedAt(sub: c['sub'] as String, aid: c['aid'] as String, iat: intOr(c['iat'])!);
    return {
      'expect': clockCorrection(
        clockNow: intOr(v['clockNow'])!,
        lastSeen: intOr(v['lastSeen']),
        claims: claims,
        heldIat: intOr(v['heldIat']),
        key: v['key'] as String,
        activationId: v['activationId'] as String,
      ),
    };
  });
  conformanceGroup('savedLastSeen',
      (v) => {'expect': savedLastSeen(intOr(v['stored']), intOr(v['clockNow'])!, intOr(v['guard']))});
}

/// The groups that pin a word of the wire.
void wireGroups() {
  conformanceGroup('mapServerError', (v) => {'expect': mapServerError(v['error']).wire});
  conformanceGroup('refusalOf', (v) => {'expect': refusalOf(v['error'])?.wire});
  conformanceGroup('enteredKey', (v) => {'expect': enteredKey(v['input'] as String)});
  conformanceGroup('trimDeviceName', (v) => {'expect': trimToLength(v['input'] as String, intOr(v['max'])!)});
  conformanceGroup('noAnswer', (v) => {'expect': noAnswer(intOr(v['status'])!)});
  conformanceGroup('parseLeaseBody', (v) {
    final body = parseLeaseBody(v['body']);
    return {
      'expect': {
        if (body.lease != null) 'lease': body.lease,
        if (body.activationId != null) 'activationId': body.activationId,
      },
    };
  });
  conformanceGroup('parseTrialBody', (v) {
    final body = parseTrialBody(v['body']);
    return {
      'expect': body == null
          ? null
          : {
              'trialStart': body.trialStart,
              'trialEndsAt': body.trialEndsAt,
              if (body.lease != null) 'lease': body.lease,
            },
    };
  });
  conformanceGroup('entitlementNumbers', (v) {
    final read = entitlementsOf(jsonDecode('{"n":${v['json']}}'))['n'];
    if (read is! NumberEntitlement) throw StateError('${v['json']} is not a number');
    return {'expect': doubleBits(read.value)};
  });
}

/// A double's IEEE-754 bits, sign first, as 16 lowercase hex digits.
String doubleBits(double value) {
  final bytes = ByteData(8)..setFloat64(0, value);
  String half(int offset) => bytes.getUint32(offset).toRadixString(16).padLeft(8, '0');
  return half(0) + half(4);
}
