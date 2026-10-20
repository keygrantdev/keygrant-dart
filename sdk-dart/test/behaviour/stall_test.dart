// One call at a time, every request bounded, and READ-ONLY behind a call that
// has not finished (engine.ts `serial`; license.test.ts, the waits and bounded
// calls). Real time, cut short: an HTTP bound of 200 ms and a lock grace of
// 300 ms, so a call waits at most 500 ms for the one before it.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';

import '../support/harness.dart';
import '../support/trials_support.dart';

final int graceMs = quickHttp.inMilliseconds + quick.lockGrace.inMilliseconds;

Future<Harness> quickHarness({Timing timing = quick, Duration httpTimeout = quickHttp}) =>
    Harness.create(timing: timing, httpTimeout: httpTimeout);

/// A refresh() whose refusal write is held inside the adapter, with `stored`
/// stored: whatever is called next runs read-only behind it once its grace is up.
Future<({Harness h, void Function() release, Future<LicenseStatus> stuck})> behindAStuckWrite(
    Future<Map<String, Object?>> Function(Harness h) stored) async {
  final h = await quickHarness();
  storeJson(h, await stored(h));
  h.http.on('validate', (_) => const HttpResponse(403, {'error': 'revoked'}));
  final release = h.storage.holdNextWrite();
  final stuck = h.license.refresh();
  await h.storage.whenWritten(1);
  expect(h.storage.writes, 1);
  return (h: h, release: release, stuck: stuck);
}

Future<Map<String, Object?>> licensed(Harness h) => licensedJson(h.signer);

void main() {
  test('lets a later call go ahead read-only when one is stuck on storage', () async {
    final h = await quickHarness();
    storeJson(h, await licensed(h));
    h.storage.hangNextRead = true;
    final watch = Stopwatch()..start();
    h.license.status().ignore();
    final later = h.license.status();
    expect(await settledWithin(later, Duration(milliseconds: graceMs - 150)), isFalse);
    expect(await later, licensedStatus(stalled: true));
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(graceMs - 20));
  });

  test('bounds a call whose HTTP adapter never answers, so the call behind it runs as usual', () async {
    final h = await quickHarness();
    storeJson(h, await licensed(h));
    h.http.hang = true;
    final refreshed = h.license.refresh();
    final later = h.license.status();
    await h.http.whenCalled('validate');
    expect(await refreshed, licensedStatus());
    // The refresh settled at its bound: the status went ahead then, writing as it may.
    expect(await later, licensedStatus());
  });

  test('bounds every request by the configured HTTP bound when the call names none', () async {
    final h = await quickHarness();
    h.http.hang = true;
    final (result, ms) = await timed(h.license.activate(key1));
    expect((result as ActivateFailed).error, LicenseError.network);
    expect(h.http.bodyOf('activate'), isNotNull);
    expect(h.http.calls.single.timeout, quickHttp);
    expect(ms, greaterThanOrEqualTo(quickHttp.inMilliseconds - 20));
  });

  test('lets no call behind a stuck one write what its late write could revert', () async {
    final s = await behindAStuckWrite(licensed);
    final lease = s.h.stored!.lease;
    s.h.renews(await s.h.signer.lease(key1));
    // Read-only: the lease still stored, licensed; not asked, nothing written.
    expect(await s.h.license.refresh(), licensedStatus(stalled: true));
    expect(posts(s.h, 'validate'), 1);
    expect(s.h.storage.writes, 1);
    expect(s.h.stored!.lease, lease);
    s.release();
    expect(await s.stuck, const LicenseStatus(LicenseState.invalid, reason: LicenseReason.revoked, key: key1));
    expect(s.h.storedJson['refused'], 'revoked');
    // The stuck call settled: the next call writes again, and heals.
    expect(await s.h.license.refresh(), licensedStatus());
    expect(posts(s.h, 'validate'), 2);
  });

  test('times the grace from when the stuck call started, however late the next is queued', () async {
    const timing = Timing(lockGrace: Duration(milliseconds: 600));
    final h = await quickHarness(timing: timing);
    storeJson(h, await licensed(h));
    h.http.on('validate', (_) => const HttpResponse(403, {'error': 'revoked'}));
    final release = h.storage.holdNextWrite();
    final watch = Stopwatch()..start();
    final stuck = h.license.refresh();
    await h.storage.whenWritten(1);
    // Well into the stuck call's grace (800 ms), the next is queued: it goes
    // ahead when that grace is up, not a whole grace after it was queued.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await h.license.status(), licensedStatus(stalled: true));
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(780));
    expect(watch.elapsedMilliseconds, lessThan(1200));
    release();
    await stuck;
  });

  test('answers activate() network behind a stuck call: no request, no write', () async {
    final s = await behindAStuckWrite(licensed);
    expect((await s.h.license.activate(key1) as ActivateFailed).error, LicenseError.network);
    expect(posts(s.h, 'activate'), 0);
    expect(s.h.storage.writes, 1);
    s.release();
  });

  test('answers restoreByEmail() network behind a stuck call, asking nothing', () async {
    final s = await behindAStuckWrite(licensed);
    expect((await s.h.license.restoreByEmail('a@b.test', '123456') as RestoreFailed).error, RestoreError.network);
    expect(s.h.http.calls.map((c) => c.action), ['validate']);
    s.release();
  });

  test('rejects deactivate() behind a stuck call: no request, and the key still stored', () async {
    final s = await behindAStuckWrite(licensed);
    await expectLater(s.h.license.deactivate(), throwsA(isA<LicenseCallUnfinished>()));
    expect(posts(s.h, 'deactivate'), 0);
    expect(s.h.stored!.key, key1);
    expect(s.h.storage.writes, 1);
    s.release();
  });

  test('rejects importLicenseFile() and removeLicenseFile() behind a stuck call, writing nothing', () async {
    final s = await behindAStuckWrite(licensed);
    await expectLater(s.h.license.importLicenseFile('not a file'), throwsA(isA<LicenseCallUnfinished>()));
    await expectLater(s.h.license.importLicenseFileBytes([1, 2, 3]), throwsA(isA<LicenseCallUnfinished>()));
    await expectLater(s.h.license.removeLicenseFile(), throwsA(isA<LicenseCallUnfinished>()));
    expect(s.h.storage.writes, 1);
    s.release();
  });

  test('answers startTrial() with the stored trial behind a stuck call: no request, no write', () async {
    final s = await behindAStuckWrite((h) async => licensedJson(h.signer, {
          'trialStart': now0,
          'trialEndsAt': now0 + 5 * day,
          'trialLease': await trialLeaseOf(h.signer),
        }));
    expect(await s.h.license.startTrial(), trialFor(5, stalled: true));
    expect(posts(s.h, 'trial'), 0);
    expect(s.h.storage.writes, 1);
    s.release();
  });

  test('answers startTrial() behind a stuck call without asking for a trial whose lease does not verify', () async {
    final other = await Signer.create();
    final s = await behindAStuckWrite((h) async => licensedJson(h.signer, {
          'trialStart': now0,
          'trialEndsAt': now0 + 5 * day,
          'trialLease': await trialLeaseOf(other),
        }));
    answersTrial(s.h, start: now0, ends: now0 + 5 * day, lease: await trialLeaseOf(s.h.signer));
    expect(await s.h.license.startTrial(),
        const LicenseStatus(LicenseState.expired, reason: LicenseReason.trial, stalled: true));
    expect(posts(s.h, 'trial'), 0);
    expect(s.h.storage.writes, 1);
    s.release();
  });

  test('answers a stored refusal behind a stuck call, without asking', () async {
    final s = await behindAStuckWrite((_) async => {'key': key1, 'activationId': 'act_1', 'refused': 'revoked', 'lastSeen': now0});
    expect(await s.h.license.status(),
        const LicenseStatus(LicenseState.invalid, reason: LicenseReason.revoked, key: key1, stalled: true));
    expect(posts(s.h, 'validate'), 1);
    s.release();
  });

  test('answers an expired stored lease as expired offline behind a stuck call, without asking', () async {
    final s = await behindAStuckWrite((h) async => {
          'key': key1,
          'activationId': 'act_1',
          'lease': await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day),
          'lastSeen': now0,
        });
    expect(await s.h.license.status(),
        const LicenseStatus(LicenseState.expired, reason: LicenseReason.offline, key: key1, stalled: true));
    expect(posts(s.h, 'validate'), 1);
    s.release();
  });

  test('keeps a trial it could not save out of a call that runs read-only behind a stuck one', () async {
    final h = await quickHarness();
    answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
    h.storage.failWrites = true;
    expect((await h.license.startTrial()).state, LicenseState.trial);
    h.storage.failWrites = false;
    final failedWrites = h.storage.writes;
    h.storage.hangNextRead = true;
    h.license.status().ignore();
    expect(await h.license.status(), trialFor(5, stalled: true));
    expect(h.storage.writes, failedWrites);
    expect(h.stored, isNull);
  });

  test('runs three calls queued at once on a slow network one after another, each asking', () async {
    final h = await Harness.create(timing: quick, httpTimeout: const Duration(seconds: 5));
    final lease = await h.signer.lease(key1);
    storeJson(h, await licensed(h));
    var inFlight = 0, most = 0;
    h.http.on('validate', (_) async {
      most = ++inFlight > most ? inFlight : most;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      inFlight--;
      return HttpResponse(200, {'lease': lease, 'activationId': 'act_1'});
    });
    final answers = await Future.wait([h.license.refresh(), h.license.refresh(), h.license.refresh()]);
    expect(answers, everyElement(licensedStatus()));
    expect(posts(h, 'validate'), 3);
    expect(most, 1);
  });

  test('answers has() and upgradeUrl() beside a stuck call, from what is stored', () async {
    final s = await behindAStuckWrite(licensed);
    expect(await s.h.license.has('anything'), isFalse);
    expect(await s.h.license.upgradeUrl('https://pay.test/x'), contains('client_reference_id=act_1'));
    s.release();
    await s.stuck;
  });
}
