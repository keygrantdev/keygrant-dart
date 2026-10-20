// The groups of the file that read a device, a renewal or a stored lease's
// status, answered as the reference's replay.ts answers them.

import 'package:keygrant/src/core/device.dart';
import 'package:keygrant/src/core/identity.dart';
import 'package:keygrant/src/core/lease.dart';
import 'package:keygrant/src/core/machine_id.dart';
import 'package:keygrant/src/core/offline.dart';
import 'package:keygrant/src/core/renewal.dart';
import 'package:keygrant/src/core/stored_state.dart';
import 'package:keygrant/src/core/types.dart';

import 'harness.dart';
import 'inputs.dart';
import 'scripted.dart';

void deviceGroups() {
  conformanceGroup('mountinfo', (v) => {'expect': machineIdFilesystem(v['mountinfo'] as String)});
  conformanceGroup('machineIds', (v) async {
    final reading = await readMachineId(Scripted(v['source'] as Map<String, Object?>), machineIdTimeout);
    return {'expect': reading.toJson()};
  });
  conformanceGroup('renewals', (v) {
    final device = deviceOf(v['device']);
    final outcome = renewalOutcome(
      response: responseOf(v['response']),
      check: checkOf(v['check']),
      askedAt: intOr(v['askedAt'])!,
      now: intOr(v['now'])!,
      major: intOr(v['major'])!,
      key: v['key'] as String?,
      keptMajor: intOr(v['keptMajor']),
      kind: device.kind,
      ownClaim: device.ownClaim,
    );
    return {
      'expect': {'answered': outcome.answered, 'status': outcome.status?.toJson(), 'patch': outcome.patch},
    };
  });
  conformanceGroup('validLeaseAsks', validLeaseAsk);
  conformanceGroup('devices', (v) {
    final i = v['identity'] as Map<String, Object?>;
    final identity = DeviceIdentity(
      fingerprint: i['fingerprint'] as String?,
      kind: DeviceKind.fromWire(i['kind']),
      alternates: texts(i['alternates']),
    );
    final device = deviceFrom(identity, DeviceKind.fromWire(v['installKind']), v['deviceHold'] as bool);
    return {'expect': device.toJson()};
  });
  conformanceGroup('identities', (v) {
    final host = v['host'] as Map<String, Object?>?;
    final names = host == null
        ? null
        : HostNames(host: host['host'] as String, platform: host['platform'] as String, arch: host['arch'] as String);
    return {'expect': identityOf(readingOf(v['reading']), names).toJson()};
  });
  conformanceGroup('leaseStatuses', (v) async {
    final holder = holderOf(v['holder']);
    final verified = await verifyLease(v['token'] as String, fileKeys(), intOr(v['now'])!);
    final check = checkLease(verified, v['product'] as String, intOr(v['major'])!, holder);
    return {'expect': leaseStatus(check, holder.key).toJson()};
  });
  conformanceGroup('trialLeaseStatuses', (v) async {
    final now = intOr(v['now'])!;
    final device = deviceOf(v['device']);
    final verified = await verifyLease(v['token'] as String, fileKeys(), now);
    final lease = trialLeaseOf(verified, v['product'] as String, device.claims, device.canTell);
    final state = StoredState.fromJson({'trialStart': v['trialStart'], 'trialLease': v['token']});
    return {'expect': trialStatusOf(state, now, lease.valid, lease.endsAt, lease.entitlements).toJson()};
  });
}

/// `validLeaseAsks` (and `syncAsks`, as it): a lease's `major`, `iat` and
/// `exp` over the base claims.
Map<String, Object?> validLeaseAsk(Map<String, Object?> v) {
  final c = v['claims'] as Map<String, Object?>;
  final claims = baseClaims(major: intOr(c['major']), iat: intOr(c['iat']), exp: intOr(c['exp']));
  final asks = asksOnValidLease(
    claims: claims,
    state: stateOf(v['state']),
    major: intOr(v['major'])!,
    now: intOr(v['now'])!,
    clockNow: intOr(v['clockNow'])!,
  );
  return {'expect': asks};
}

/// A machine-id reading as a vector gives it.
MachineIdReading readingOf(Object? json) {
  final r = json as Map<String, Object?>;
  return switch (r['kind']) {
    'id' => MachineIdFound(r['id'] as String),
    'unavailable' => const MachineIdUnavailable(),
    _ => const MachineIdTransient(),
  };
}
