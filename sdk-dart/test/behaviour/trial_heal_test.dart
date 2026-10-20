// A trial whose lease does not verify while its stored end is ahead: asked
// for again under the usual waits (license.test.ts `trial`, the heal).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/offline.dart' show askAgainMs, retryUnansweredMs;

import '../support/harness.dart';
import '../support/trials_support.dart';

/// A harness holding a trial whose lease another key signed (one the product
/// signed before a rotation).
Future<Harness> rotated(
    {Map<String, Object?> over = const {},
    Fingerprinter? fingerprinter,
    Timing timing = Timing.standard,
    Duration httpTimeout = const Duration(seconds: 15)}) async {
  final h = await Harness.create(fingerprinter: fingerprinter, timing: timing, httpTimeout: httpTimeout);
  final stale = await trialLeaseOf(await Signer.create());
  storeJson(h, await runningTrial(h.signer, {'trialLease': stale, ...over}));
  return h;
}

void main() {
  test("asks for the trial again, and the server's fresh lease runs it", () async {
    final h = await rotated();
    final fresh = await trialLeaseOf(h.signer);
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: fresh);
    expect(await h.license.status(), trialFor(5));
    expect(posts(h, 'trial'), 1);
    expect(h.stored!.trialLease, fresh);
    // Healed, so no wait is recorded, and the next status() needs no ask.
    expect(h.stored!.backoffSince, isNull);
    await h.license.status();
    expect(posts(h, 'trial'), 1);
  });

  test("heals a trial lease signed short of the trial's end", () async {
    final h = await Harness.create();
    storeJson(h, {'trialStart': now0, 'trialEndsAt': now0 + 14 * day, 'trialLease': await trialLeaseOf(h.signer, days: 7), 'lastSeen': now0});
    h.clock.value = now0 + 8 * day;
    answersTrial(h, start: now0, ends: now0 + 14 * day, lease: await trialLeaseOf(h.signer, days: 6, at: now0 + 8 * day));
    final status = await h.license.status();
    expect(status.state, LicenseState.trial);
    expect(status.trialDaysLeft, 6);
  });

  test('answers expired, and waits a minute, when the server cannot be reached', () async {
    final h = await rotated();
    h.http.fail = true;
    expect(await h.license.status(), trialOver);
    expect(h.stored!.backoffSince, now0);
    expect(h.stored!.backoffMs, retryUnansweredMs);
    await h.license.status();
    expect(posts(h, 'trial'), 1);
    h.clock.value = now0 + retryUnansweredMs;
    await h.license.status();
    expect(posts(h, 'trial'), 2);
  });

  test('times the wait by the device clock, not the guard, when the clock was set back', () async {
    final h = await rotated(over: {'lastSeen': now0 + day});
    h.http.fail = true;
    expect(await h.license.status(), trialOver);
    expect(h.stored!.backoffSince, now0);
    expect(h.stored!.backoffMs, retryUnansweredMs);
    await h.license.status();
    expect(posts(h, 'trial'), 1);
  });

  test('waits an hour when the server answers with nothing this build can verify', () async {
    final h = await rotated();
    final stillStale = await trialLeaseOf(await Signer.create());
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: stillStale);
    expect(await h.license.status(), trialOver);
    expect(h.stored!.backoffSince, now0);
    expect(h.stored!.backoffMs, askAgainMs);
    // Neither verifies, so nothing is kept over the server's: its lease is the one stored.
    expect(h.stored!.trialLease, stillStale);
  });

  test('asks nothing on a run that cannot tell who the device is, and waits a minute', () async {
    final h = await rotated(fingerprinter: const FailingFingerprinter());
    expect(await h.license.status(), trialOver);
    expect(h.http.called('trial'), isFalse);
    expect(h.stored!.backoffSince, now0);
    expect(h.stored!.backoffMs, retryUnansweredMs);
  });

  test("takes the server's word that the trial is over", () async {
    final h = await rotated();
    answersTrial(h, start: now0 - 9 * day, ends: now0 - 2 * day);
    expect(await h.license.status(), trialOver);
    expect(h.stored!.trialEndsAt, now0 - 2 * day);
  });

  test('asks again inside the wait when refreshed', () async {
    final h = await rotated(over: {'backoffSince': now0 - 60000, 'backoffMs': askAgainMs});
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    expect(await h.license.status(), trialOver);
    expect(h.http.called('trial'), isFalse);
    expect(await h.license.refresh(), trialFor(5));
  });

  test('neither asks nor writes behind a call that has not finished', () async {
    final h = await rotated(timing: quick, httpTimeout: quickHttp);
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    h.storage.hangNextRead = true;
    h.license.status().ignore();
    expect(await h.license.status(), const LicenseStatus(LicenseState.expired, reason: LicenseReason.trial, stalled: true));
    expect(h.http.called('trial'), isFalse);
    expect(h.storage.writes, 0);
  });

  test('waits an hour after a 404, and after a 200 it cannot read, the server having answered', () async {
    for (final answer in [
      const HttpResponse(404, {'error': 'unknown-product'}),
      const HttpResponse(200, {'trialStart': 'soon'}),
    ]) {
      final h = await rotated();
      h.http.on('trial', (_) => answer);
      expect(await h.license.status(), trialOver);
      expect(h.stored!.backoffSince, now0);
      expect(h.stored!.backoffMs, askAgainMs);
    }
  });

  test('asks nothing when the stored end is exactly now', () async {
    final h = await rotated(over: {'trialEndsAt': now0});
    expect(await h.license.status(), trialOver);
    expect(h.http.called('trial'), isFalse);
  });

  test('bounds its ask as a status check is, and waits a minute after one that got no answer', () async {
    final h = await rotated(timing: quick);
    h.http.hang = true;
    final pending = h.license.status();
    await h.http.whenCalled('trial');
    final (status, ms) = await timed(pending);
    expect(ms, greaterThanOrEqualTo(quick.statusCheck.inMilliseconds - 50));
    expect(ms, lessThan(5000));
    expect(status, trialOver);
    expect(h.stored!.backoffSince, now0);
    expect(h.stored!.backoffMs, retryUnansweredMs);
  });

  test('reads the machine id for its ask with the bound a status() gets, not the activation bound', () async {
    final stuck = StuckFingerprinter();
    final h = await rotated(fingerprinter: stuck, timing: quick);
    final (status, ms) = await timed(h.license.status());
    // The stored lease's check reads the device first; then the heal reads it again.
    expect(stuck.reads, 2);
    expect(ms, greaterThanOrEqualTo(2 * quick.machineId.inMilliseconds - 40));
    expect(ms, lessThan(2 * quick.machineId.inMilliseconds + quick.activateMachineId.inMilliseconds));
    expect(status, trialOver);
    expect(h.http.called('trial'), isFalse);
    expect(h.stored!.backoffMs, retryUnansweredMs);
  });

  test('asks nothing once the stored end has passed, or when the lease verifies', () async {
    final h = await rotated(over: {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 - 1});
    expect(await h.license.status(), trialOver);
    expect(h.http.called('trial'), isFalse);

    final valid = await Harness.create();
    // Synced within the day, so no launch report is due either.
    storeJson(valid, await runningTrial(valid.signer, {'trialAt': now0 - day ~/ 2}));
    expect((await valid.license.status()).state, LicenseState.trial);
    await valid.license.launchReportSettled();
    expect(valid.http.called('trial'), isFalse);
  });
}
