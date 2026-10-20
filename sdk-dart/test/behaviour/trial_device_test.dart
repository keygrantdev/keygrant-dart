// A trial held to its device, and the device reads a trial makes (the Swift
// port's TrialTests, TrialHealTests and LaunchReportTests; license.test.ts, a
// trial lease held to its device).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/keys.dart' show fingerprintClaim;

import '../support/harness.dart';
import '../support/trials_support.dart';

/// A trial lease started under `device`, a fingerprint of `kind`, as the server signs one.
Future<String> deviceTrialLease(Signer s, String device, {String kind = 'machine', int days = 7}) {
  final claim = fingerprintClaim(device);
  return s.lease('trial:$claim', model: 'trial', aid: claim, ttlSeconds: days * 86400, extra: {'fpk': kind});
}

/// A fingerprinter that cannot tell, recording the bound each read is given.
final class BoundsFingerprinter extends Fingerprinter {
  final List<Duration> bounds = [];
  @override
  Future<String> get() async => 'unused';
  @override
  Future<DeviceIdentity> identify(Duration timeout) async {
    bounds.add(timeout);
    return const DeviceIdentity(fingerprint: null);
  }
}

/// A fingerprinter whose first read cannot tell; the next waits at `gate`.
final class GatedFingerprinter extends Fingerprinter {
  final Completer<void> gate = Completer();
  final Completer<void> secondRead = Completer();
  int reads = 0;
  @override
  Future<String> get() async {
    if (++reads == 1) throw StateError('cannot tell');
    secondRead.complete();
    await gate.future;
    return 'fp-test';
  }
}

void main() {
  test('starts no trial on a run that cannot tell who the device is', () async {
    final h = await Harness.create(fingerprinter: const FailingFingerprinter());
    expect(await h.license.startTrial(), const LicenseStatus(LicenseState.unlicensed));
    expect(h.http.called('trial'), isFalse);
  });

  test('keeps a fourteen-day trial live on its tenth day offline, on the lease signed to its end', () async {
    final h = await Harness.create();
    answersTrial(h, start: now0, ends: now0 + 14 * day, lease: await trialLeaseOf(h.signer, days: 14));
    expect(await h.license.startTrial(), trialFor(14));
    h.http.fail = true;
    h.clock.value = now0 + 10 * day;
    expect(await h.license.status(),
        const LicenseStatus(LicenseState.trial, trialEndsAt: now0 + 14 * day, trialDaysLeft: 4));
    await h.license.launchReportSettled();
    expect(h.http.calls.map((c) => c.action), ['trial', 'trial']);
    expect(h.stored!.trialEndsAt, now0 + 14 * day);
    expect(h.stored!.trialReportedAt, now0 + 10 * day);
  });

  test("runs on this device's trial lease, and not on another's", () async {
    final mine = await Harness.create();
    storeJson(mine, {'trialStart': now0, 'trialLease': await deviceTrialLease(mine.signer, 'fp-test'), 'lastSeen': now0, 'trialAt': now0});
    expect((await mine.license.status()).state, LicenseState.trial);

    final theirs = await Harness.create();
    storeJson(theirs, {
      'trialStart': now0 - 30 * day,
      'trialLease': await deviceTrialLease(theirs.signer, 'fp-another-machine'),
      'lastSeen': now0,
    });
    expect(await theirs.license.status(), trialOver);
  });

  test('runs on a lease started under a host name, whatever device it names', () async {
    final h = await Harness.create();
    storeJson(h, {
      'trialStart': now0 - 30 * day,
      'trialLease': await deviceTrialLease(h.signer, 'fp-another-machine', kind: 'hostname'),
      'lastSeen': now0,
      'trialAt': now0,
    });
    expect((await h.license.status()).state, LicenseState.trial);
  });

  test('does not judge a trial lease on a run that cannot tell', () async {
    final h = await Harness.create(fingerprinter: const FailingFingerprinter());
    storeJson(h, {'trialStart': now0, 'trialLease': await deviceTrialLease(h.signer, 'fp-another-machine'), 'lastSeen': now0});
    expect((await h.license.status()).state, LicenseState.trial);
  });

  test("takes no licence's lease in the trial's place", () async {
    final h = await Harness.create();
    storeJson(h, {'trialStart': now0 - 30 * day, 'trialLease': await h.signer.lease(key1), 'lastSeen': now0});
    expect(await h.license.status(), trialOver);
  });

  test('does not ask again after the answer startTrial() got, and records no wait', () async {
    final h = await Harness.create();
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(await Signer.create()));
    expect(await h.license.startTrial(), trialOver);
    expect(posts(h, 'trial'), 1);
    expect(h.stored!.backoffSince, isNull);
  });

  test('the launch report reads the device with the status bound, and sends nothing when it cannot tell', () async {
    final bounds = BoundsFingerprinter();
    final h = await Harness.create(fingerprinter: bounds);
    storeJson(h, await runningTrial(h.signer));
    expect(await h.license.status(), trialFor(5));
    await h.license.launchReportSettled();
    // The status's own read, then the report's: each given a status's bound, never an activation's.
    expect(bounds.bounds, [const Duration(seconds: 2), const Duration(seconds: 2)]);
    expect(h.http.called('trial'), isFalse);
    expect(h.stored!.trialReportedAt, now0);
  });

  test('the launch report reads the device in the background too', () async {
    final gated = GatedFingerprinter();
    final h = await Harness.create(fingerprinter: gated);
    storeJson(h, await runningTrial(h.signer));
    expect(await h.license.status().timeout(const Duration(seconds: 5)), trialFor(5));
    await gated.secondRead.future.timeout(const Duration(seconds: 5));
    expect(h.http.called('trial'), isFalse);
    gated.gate.complete();
    await h.license.launchReportSettled();
    expect(h.http.bodyOf('trial')['fingerprint'], 'fp-test');
  });
}
