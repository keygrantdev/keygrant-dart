// The clock guard: rewinding the clock never brings an expired lease back,
// and a fresh lease brings a guard that jumped ahead back (clock.ts
// `clockCorrection`; license.test.ts 'the waits, early renewal, bounded calls
// and the clock guard'; ClockTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/clock.dart' show clockToleranceMs;

import '../support/harness.dart';
import '../support/status_support.dart';

/// The guard after a refresh() answered with a fresh lease signed at now0, the clock at `clock`.
Future<int?> guardAfterRefresh(int guard, [int clock = now0]) async {
  final h = await Harness.create();
  final lease = await h.signer.lease(key1);
  holding(h, lease, {'lastSeen': guard});
  h.clock.value = clock;
  h.renews(lease);
  expect((await h.license.refresh()).state, LicenseState.licensed);
  return h.stored?.lastSeen;
}

void main() {
  test('never brings an expired lease back with the clock put back', () async {
    final h = await Harness.create();
    final lease = await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day);
    holding(h, lease, {'lastSeen': now0 + 10 * day});
    h.clock.value = now0 - 5 * day;
    h.http.fail = true;
    expect(await statusOf(h.license), expiredOffline);
  });

  test('judges a valid lease by the guard, not by a clock put back before it was signed', () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1, ttlSeconds: 2 * 86400), {'lastSeen': now0 + 3 * day});
    h.clock.value = now0;
    h.http.fail = true;
    expect(await statusOf(h.license), expiredOffline);
  });

  test('advances the guard on every save', () async {
    final h = await Harness.create();
    store(h, {'lastSeen': now0 - day});
    h.activates(await h.signer.lease(key1));
    await h.license.activate(key1);
    expect(h.stored?.lastSeen, now0);
  });

  test('licenses again online after a clock that jumped 60 days ahead is put right', () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1, at: now0 - day), {'lastSeen': now0 + 60 * day});
    h.renews(await h.signer.lease(key1));
    expect(await statusOf(h.license), licensedJson);
    expect(h.stored?.lastSeen, now0);
    h.http.fail = true;
    expect(await statusOf(h.license), licensedJson);
  });

  test('stamps an activation and a deactivation with their time, as answers to an ask', () async {
    final h = await Harness.create();
    h.activates(await h.signer.lease(key1));
    h.http.on('deactivate', (_) => const HttpResponse(200, {'ok': true}));
    await h.license.activate(key1);
    expect(h.stored?.verdictAt, now0);
    h.clock.value = now0 + day;
    await h.license.deactivate();
    expect(h.stored?.verdictAt, now0 + day);
  });

  test('stamps by the guarded clock: never earlier than the last time seen, with the clock put back', () async {
    final h = await Harness.create();
    const seen = now0 + 5 * 60000;
    store(h, {'lastSeen': seen});
    h.activates(await h.signer.lease(key1));
    h.http.on('deactivate', (_) => const HttpResponse(200, {'ok': true}));
    final trialLease = await h.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 5 * 86400);
    h.http.on('trial', (_) => HttpResponse(200, {'trialStart': now0, 'trialEndsAt': now0 + 5 * day, 'lease': trialLease}));
    await h.license.activate(key1);
    expect(h.stored?.verdictAt, seen);
    h.clock.value = now0 - day;
    await h.license.deactivate();
    expect(h.stored?.verdictAt, seen);
    await h.license.startTrial();
    expect(h.stored?.trialAt, seen);
  });

  test('saves its own answers after the clock is put back: one process never supersedes itself', () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1, at: now0 - day), {'verdictAt': now0 + 60 * day});
    refuses(h, 'revoked');
    expect(await refreshOf(h.license), invalid('revoked'));
    expect(h.stored?.refused, Refusal.revoked);
    expect(h.stored?.verdictAt, now0);
    expect(h.stored?.lease, isNull);
  });

  test("licenses from the server's lease when the guard it puts right cannot be saved", () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1, at: now0 - day), {'lastSeen': now0 + 60 * day});
    h.renews(await h.signer.lease(key1));
    h.storage.failWrites = true;
    expect(await statusOf(h.license), licensedJson);
    expect(h.stored?.lastSeen, now0 + 60 * day);
  });

  test("licenses from a renewal whose check of the server's time cannot read the state just then", () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day));
    final fresh = await h.signer.lease(key1);
    h.renews(fresh);
    // The status's own read is the first; the renewal's check of the time, the second.
    h.storage.failRead(2);
    expect(await statusOf(h.license), licensedJson);
    expect(h.stored?.lease, fresh);
  });

  test('leaves the guard where it is for a fresh lease within the tolerance of it', () async {
    expect(await guardAfterRefresh(now0 + 30 * 60000), now0 + 30 * 60000);
    expect(await guardAfterRefresh(now0 + clockToleranceMs), now0 + clockToleranceMs);
  });

  test('brings the guard back for a fresh lease signed 1 ms past the tolerance before it', () async {
    expect(await guardAfterRefresh(now0 + clockToleranceMs + 1), now0);
  });

  test("brings the guard back to the lease's signing time, not to a device clock behind it", () async {
    expect(await guardAfterRefresh(now0 + 60 * day, now0 - 2 * 3600000), now0);
  });

  test('brings the guard back to the device clock when that is after the signing time', () async {
    expect(await guardAfterRefresh(now0 + 60 * day, now0 + 3 * 3600000), now0 + 3 * 3600000);
  });

  test('brings the guard back for a lease naming the key in another case, as the server matches it', () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1), {'lastSeen': now0 + 60 * day});
    h.renews(await h.signer.lease('Sluice-aaaa-BBBB-CCCC-DDDD'));
    await h.license.refresh();
    expect(h.stored?.lastSeen, now0);
  });

  for (final (name, sub, aid, at) in [
    ('another key', 'SLUICE-OTHR-OTHR-OTHR-OTHR', 'act_1', now0),
    ('another activation', key1, 'act_2', now0),
    ('a lease older than the one the device holds', key1, 'act_1', now0 - day),
  ]) {
    test('moves no guard for a lease signed for $name', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1), {'lastSeen': now0 + 60 * day});
      final answer = await h.signer.lease(sub, aid: aid, at: at);
      answers(h, 200, {'lease': answer, 'activationId': aid});
      await h.license.refresh();
      expect(h.stored?.lastSeen, now0 + 60 * day);
    });
  }

  test('moves no guard for a lease that does not verify', () async {
    final h = await Harness.create();
    holding(h, await h.signer.lease(key1), {'lastSeen': now0 + 60 * day});
    final other = await Signer.create();
    answers(h, 200, {'lease': await other.lease(key1), 'activationId': 'act_1'});
    await h.license.refresh();
    expect(h.stored?.lastSeen, now0 + 60 * day);
  });
}
