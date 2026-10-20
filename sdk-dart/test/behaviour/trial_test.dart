// startTrial() and a trial's status (the SDK contract, 5.4; license.test.ts `trial`).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/harness.dart';
import '../support/trials_support.dart';

void main() {
  test('starts a trial, verifies the lease, and stashes the start earliest', () async {
    final h = await Harness.create();
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    final status = await h.license.startTrial();
    expect(status.state, LicenseState.trial);
    expect(status.trialDaysLeft, 5);
    expect(h.stored!.trialStart, now0 - 2 * day);
    expect(h.stash.start, now0 - 2 * day);
  });

  test('never moves the trial start forward (anti-reset)', () async {
    final h = await Harness.create(initial: StoredState.fromJson({'trialStart': now0 - 10 * day}));
    h.stash.start = now0 - 8 * day;
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 4 * day, lease: await trialLeaseOf(h.signer, days: 4));
    await h.license.startTrial();
    expect(h.stored!.trialStart, now0 - 10 * day);
  });

  test('restores the earliest start from the stash when the stored state was wiped', () async {
    final h = await Harness.create();
    h.stash.start = now0 - 10 * day;
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    await h.license.startTrial();
    expect(h.stored!.trialStart, now0 - 10 * day);
  });

  test('falls back to the trial evidence held here when offline', () async {
    final h = await Harness.create();
    storeJson(h, await runningTrial(h.signer, {'trialStart': now0 - day, 'trialEndsAt': now0 + 6 * day, 'trialLease': await trialLeaseOf(h.signer, days: 6)}));
    h.http.fail = true;
    expect((await h.license.startTrial()).state, LicenseState.trial);
  });

  test('falls back to the evidence held here when the trial endpoint answers other than 200', () async {
    final h = await Harness.create();
    final lease = await trialLeaseOf(h.signer, days: 6);
    storeJson(h, await runningTrial(h.signer, {'trialStart': now0 - day, 'trialEndsAt': now0 + 6 * day, 'trialLease': lease}));
    // A trial-shaped body that would end the trial, were anything but a 200 taken.
    h.http.on('trial', (_) => const HttpResponse(400, {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 - 2 * day}));
    expect((await h.license.startTrial()).state, LicenseState.trial);
    expect(h.storedJson['trialEndsAt'], now0 + 6 * day);
    expect(h.storedJson['trialLease'], lease);
  });

  test('asks with the earliest start the device holds, the stash or the stored one', () async {
    for (final (stored, stashed) in [(now0 - 3 * day, now0 - 5 * day), (now0 - 5 * day, now0 - 3 * day)]) {
      final h = await Harness.create(initial: StoredState.fromJson({'trialStart': stored}));
      h.stash.start = stashed;
      answersTrial(h, start: now0 - 5 * day, ends: now0 + 5 * day);
      await h.license.startTrial();
      expect(h.http.bodyOf('trial')['clientStart'], now0 - 5 * day);
    }
  });

  test('waits the activation bound for the machine id when a trial is started', () async {
    final stuck = StuckFingerprinter();
    final h = await Harness.create(fingerprinter: stuck, timing: quick);
    final (status, ms) = await timed(h.license.startTrial());
    // This device could not be told: no trial is asked for, and none is held.
    expect(status, const LicenseStatus(LicenseState.unlicensed));
    expect(ms, greaterThanOrEqualTo(quick.activateMachineId.inMilliseconds - 20));
    expect(h.http.called('trial'), isFalse);
  });

  test('answers unlicensed for a trial lease stored without a start, asking nothing', () async {
    final h = await Harness.create();
    storeJson(h, {'trialEndsAt': now0 + 5 * day, 'trialLease': await trialLeaseOf(h.signer), 'lastSeen': now0});
    expect(await h.license.status(), const LicenseStatus(LicenseState.unlicensed));
    expect(h.http.called('trial'), isFalse);
  });

  test('tells the server a machine id keys the trial, and says nothing of a fingerprint of no kind', () async {
    final h = await Harness.create(
        fingerprinter: const IdentityFingerprinter(DeviceIdentity(fingerprint: 'fp-machine', kind: DeviceKind.machine)));
    answersTrial(h, start: now0, ends: now0 + 5 * day);
    await h.license.startTrial();
    expect(h.http.bodyOf('trial'), containsPair('fingerprint', 'fp-machine'));
    expect(h.http.bodyOf('trial'), containsPair('fingerprintKind', 'machine'));

    final plain = await Harness.create();
    answersTrial(plain, start: now0, ends: now0 + 5 * day);
    await plain.license.startTrial();
    expect(plain.http.bodyOf('trial').containsKey('fingerprintKind'), isFalse);
  });

  test('takes a valid trial lease the server answers with over the valid one stored', () async {
    final h = await Harness.create();
    storeJson(h, await runningTrial(h.signer, {'trialStart': now0 - 4 * day, 'trialEndsAt': now0 + 3 * day, 'trialLease': await trialLeaseOf(h.signer, days: 3)}));
    final extended = await trialLeaseOf(h.signer, days: 6, ent: {'edition': 'pro'});
    answersTrial(h, start: now0 - 4 * day, ends: now0 + 6 * day, lease: extended);
    final status = await h.license.startTrial();
    expect(status.toJson(), {
      'state': 'trial',
      'trialEndsAt': now0 + 6 * day,
      'trialDaysLeft': 6,
      'entitlements': {'edition': 'pro'},
    });
    expect(h.stored!.trialLease, extended);
  });

  test('saves its answer over a stored trial stamped ahead of the clock, the stamp being the one it saw', () async {
    final h = await Harness.create();
    storeJson(h, await runningTrial(h.signer, {'trialStart': now0 - 5 * day, 'trialEndsAt': now0 + 2 * day, 'trialLease': await trialLeaseOf(h.signer, days: 2), 'trialAt': now0 + day}));
    final fresh = await trialLeaseOf(h.signer, days: 4);
    answersTrial(h, start: now0 - 5 * day, ends: now0 + 4 * day, lease: fresh);
    await h.license.startTrial();
    expect(h.storedJson['trialEndsAt'], now0 + 4 * day);
    expect(h.storedJson['trialLease'], fresh);
  });

  test('ignores a malformed trial body', () async {
    final h = await Harness.create();
    h.http.on('trial', (_) => const HttpResponse(200, {'trialStart': 'oops', 'lease': 'x'}));
    expect((await h.license.startTrial()).state, LicenseState.unlicensed);
    expect(h.stored?.trialStart, isNull);
  });

  test('starts the trial all the same when the stash cannot be read, and mirrors the start to it', () async {
    final h = await Harness.create();
    h.stash.failRead = true;
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    final status = await h.license.startTrial();
    expect(status.state, LicenseState.trial);
    expect(status.trialDaysLeft, 5);
    expect(h.stored!.trialStart, now0 - 2 * day);
    expect(h.http.lastBodyOf('trial').containsKey('clientStart'), isFalse);
    expect(h.stash.start, now0 - 2 * day);
  });

  test("takes the stored start as the client's, and saves the earliest, when the stash cannot be read", () async {
    final h = await Harness.create(initial: StoredState.fromJson({'trialStart': now0 - 5 * day, 'lastSeen': now0}));
    h.stash.failRead = true;
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    expect((await h.license.startTrial()).trialDaysLeft, 5);
    expect(h.http.bodyOf('trial')['clientStart'], now0 - 5 * day);
    expect(h.stored!.trialStart, now0 - 5 * day);
    expect(h.stash.start, now0 - 5 * day);
  });

  test("keeps the server's trial when the stash cannot be written", () async {
    final h = await Harness.create();
    h.stash.failWrite = true;
    final lease = await trialLeaseOf(h.signer);
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: lease);
    expect((await h.license.startTrial()).trialDaysLeft, 5);
    expect(h.storedJson, containsPair('trialStart', now0 - 2 * day));
    expect(h.storedJson, containsPair('trialEndsAt', now0 + 5 * day));
    expect(h.storedJson, containsPair('trialLease', lease));
    expect(h.stash.start, isNull);
  });

  test('runs no trial on a stored end alone: unsigned, it could be edited into any trial', () async {
    final h = await Harness.create(initial: StoredState.fromJson({'trialStart': now0 - 2 * day, 'trialEndsAt': now0 + 5 * day}));
    expect(await h.license.status(), trialOver);
  });

  test('ends a trial when its signed lease ends, whatever end is stored beside it', () async {
    final h = await Harness.create();
    storeJson(h, await runningTrial(h.signer, {'trialStart': now0 - 5 * day, 'trialEndsAt': now0 + 365 * day, 'trialLease': await trialLeaseOf(h.signer, days: 2), 'trialAt': now0}));
    expect(await h.license.status(), trialFor(2));
    h.clock.value = now0 + 2 * day + 1000;
    expect(await h.license.status(), trialOver);
  });

  test('reports expired once the trial window has passed', () async {
    final h = await Harness.create(initial: StoredState.fromJson({'trialStart': now0 - 10 * day, 'trialEndsAt': now0 - day}));
    expect(await h.license.status(), trialOver);
  });

  test('is live from a valid trial lease via status()', () async {
    final h = await Harness.create();
    storeJson(h, await runningTrial(h.signer));
    expect(await h.license.status(), trialFor(5));
  });

  test('keeps the trial lease it can verify when the server answers with one it cannot', () async {
    final h = await Harness.create();
    final ours = await trialLeaseOf(h.signer);
    storeJson(h, await runningTrial(h.signer, {'trialLease': ours}));
    final rotated = await trialLeaseOf(await Signer.create());
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: rotated);
    expect(await h.license.startTrial(), trialFor(5));
    expect(h.stored!.trialLease, ours);
  });

  test("takes the server's word when it says the trial is over, whatever lease is held", () async {
    final h = await Harness.create();
    storeJson(h, await runningTrial(h.signer));
    answersTrial(h, start: now0 - 9 * day, ends: now0 - 2 * day);
    expect(await h.license.startTrial(), trialOver);
  });

  test("takes the trial's end from its lease when none is stored", () async {
    final h = await Harness.create();
    storeJson(h, {'trialStart': now0 - 2 * day, 'trialLease': await trialLeaseOf(h.signer, days: 7), 'lastSeen': now0, 'trialAt': now0});
    expect(await h.license.status(), trialFor(7));
  });

  test('stamps a trial answer by the guarded clock, never earlier than the last time seen', () async {
    final h = await Harness.create(initial: StoredState.fromJson({'lastSeen': now0 + 5 * 60000}));
    answersTrial(h, start: now0, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    h.clock.value = now0 - day;
    await h.license.startTrial();
    expect(h.stored!.trialAt, now0 + 5 * 60000);
  });

  test('ignores members of a trial answer it does not know', () async {
    final h = await Harness.create();
    final lease = await trialLeaseOf(h.signer);
    h.http.on('trial', (_) => HttpResponse(200, {
          'trialStart': now0,
          'trialEndsAt': now0 + 5 * day,
          'lease': lease,
          'future': {'nested': [1, 2]},
          'note': 'added by a later server',
        }));
    expect(await h.license.startTrial(), trialFor(5));
  });
}
