// The waits before asking again, early renewal, and a save that fails once the
// server has answered (license.test.ts 'the waits, early renewal, bounded
// calls and the clock guard', 'a save that fails once the server has
// answered'; ClockTests.swift, RefusalTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/offline.dart' show askAgainMs, renewWithinMs, retryUnansweredMs;

import '../support/harness.dart';
import '../support/status_support.dart';

Future<String> expired(Harness h) => h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day);

void main() {
  group('the waits', () {
    for (final (name, stored) in <(String, Future<Map<String, Object?>> Function(Harness))>[
      ('a stored refusal', (h) async => {'key': key1, 'activationId': 'act_1', 'refused': 'revoked'}),
      ('a lease past its end', (h) async => {'key': key1, 'activationId': 'act_1', 'lease': await expired(h), 'checkedMajor': 1}),
      (
        'a valid lease near its end',
        (h) async => {'key': key1, 'activationId': 'act_1', 'lease': await h.signer.lease(key1, at: now0 - 26 * day), 'checkedMajor': 1}
      ),
    ]) {
      test('times the wait before asking again by the device clock, not the guard: $name', () async {
        // The guard is a day ahead of the device clock, and the last ask was half
        // an hour ago by the device clock: its hour's wait is not over.
        final h = await Harness.create();
        store(h, {...await stored(h), 'backoffSince': now0 - 30 * 60000, 'backoffMs': askAgainMs, 'lastSeen': now0 + day});
        h.http.fail = true;
        await h.license.status();
        expect(h.http.called('validate'), isFalse);
      });
    }

    test('asks at once when the device clock reads before the recorded ask', () async {
      final h = await Harness.create();
      holding(h, await expired(h), {'backoffSince': now0 + 30 * 60000, 'backoffMs': askAgainMs});
      h.http.fail = true;
      await h.license.status();
      expect(validates(h), 1);
    });

    test('starts the wait after a renewal by the device clock, not the guard', () async {
      final h = await Harness.create();
      holding(h, await expired(h), {'lastSeen': now0 + day});
      h.http.fail = true;
      expect(await statusOf(h.license), expiredOffline);
      expect(h.stored?.backoffSince, now0);
      expect(h.stored?.backoffMs, retryUnansweredMs);
    });

    test('heals a lease that ran out offline within the short wait once the network is back', () async {
      final h = await Harness.create();
      holding(h, await expired(h));
      h.http.fail = true;
      expect(await statusOf(h.license), expiredOffline);
      h.http.fail = false;
      h.renews(await h.signer.lease(key1));
      h.clock.value = now0 + retryUnansweredMs - 1;
      expect((await h.license.status()).state, LicenseState.expired);
      h.clock.value = now0 + retryUnansweredMs;
      expect(await statusOf(h.license), licensedJson);
    });

    test('still waits the hour after a refusal, the short wait notwithstanding', () async {
      final h = await Harness.create();
      holding(h, await expired(h));
      refuses(h, 'revoked');
      expect((await h.license.status()).reason, LicenseReason.revoked);
      h.clock.value = now0 + retryUnansweredMs;
      await h.license.status();
      expect(validates(h), 1);
      h.clock.value = now0 + askAgainMs;
      await h.license.status();
      expect(validates(h), 2);
    });

    test('heals a lease that does not verify only under the waits', () async {
      final h = await Harness.create();
      holding(h, await unnamedLease(await Signer.create(), key1));
      h.http.fail = true;
      expect(await statusOf(h.license), {'state': 'invalid', 'reason': 'tampered'});
      await h.license.status();
      expect(validates(h), 1);
      h.clock.value = now0 + retryUnansweredMs;
      await h.license.status();
      expect(validates(h), 2);
    });
  });

  group('early renewal', () {
    test('renews a lease early once it is within renewWithinMs of its end, and not before', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1));
      final renewed = await h.signer.lease(key1, at: now0 + 30 * day - renewWithinMs);
      h.renews(renewed);
      h.clock.value = now0 + 30 * day - renewWithinMs - 1;
      expect((await h.license.status()).state, LicenseState.licensed);
      expect(validates(h), 0);
      h.clock.value = now0 + 30 * day - renewWithinMs + 1;
      expect((await h.license.status()).state, LicenseState.licensed);
      expect(validates(h), 1);
      expect(h.stored?.lease, renewed);
      await h.license.status();
      expect(validates(h), 1);
    });

    test('renews a short lease at half its life, not on every status()', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1, model: 'subscription', ttlSeconds: 7 * 86400));
      h.http.fail = true;
      h.clock.value = now0 + 7 * day ~/ 2 - 1;
      await h.license.status();
      expect(validates(h), 0);
      h.clock.value = now0 + 7 * day ~/ 2 + 1;
      await h.license.status();
      expect(validates(h), 1);
    });

    test('keeps the valid lease when an early renewal gets nothing, and waits before trying again', () async {
      final h = await Harness.create();
      final lease = await h.signer.lease(key1);
      holding(h, lease);
      h.http.fail = true;
      const at = now0 + 25 * day;
      h.clock.value = at;
      expect(await statusOf(h.license), licensedJson);
      expect(h.stored?.lease, lease);
      expect(h.stored?.backoffSince, at);
      expect(h.stored?.backoffMs, retryUnansweredMs);
      await h.license.status();
      expect(validates(h), 1);
    });

    test('answers a refusal to an early renewal: the server no longer stands behind the lease', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1, model: 'subscription', ttlSeconds: 7 * 86400));
      refuses(h, 'expired');
      h.clock.value = now0 + 5 * day;
      expect(await statusOf(h.license), invalid('revoked'));
    });

    test('saves an early renewal for a lower major, and reports upgrade', () async {
      final h = await Harness.create(major: 2);
      final held = await h.signer.lease(key1, major: 2, at: now0 - 29 * day);
      holding(h, held, {'checkedMajor': 2});
      final lower = await h.signer.lease(key1);
      answers(h, 200, {'lease': lower, 'activationId': 'act_1'});
      expect(await statusOf(h.license), invalid('upgrade'));
      expect(h.stored?.lease, lower);
    });
  });

  group('a save that fails once the server has answered', () {
    test("is the server's refusal all the same, the stored lease untouched", () async {
      final h = await Harness.create();
      final lease = await h.signer.lease(key1);
      holding(h, lease);
      refuses(h, 'revoked');
      h.storage.failWrites = true;
      expect(await refreshOf(h.license), invalid('revoked'));
      expect(h.storage.writes, greaterThan(0));
      expect(h.stored?.lease, lease);
    });

    test("is the server's renewal all the same, for a lease that had run out", () async {
      final h = await Harness.create();
      final old = await expired(h);
      holding(h, old);
      final fresh = await h.signer.lease(key1);
      h.renews(fresh);
      h.storage.failWrites = true;
      expect(await statusOf(h.license), licensedJson);
      expect(h.stored?.lease, old);
      // Written by the next call that can.
      h.storage.failWrites = false;
      expect(await refreshOf(h.license), licensedJson);
      expect(h.stored?.lease, fresh);
    });

    test('is no answer at all, rather than a throw, when nothing answered either', () async {
      final h = await Harness.create();
      holding(h, await expired(h));
      h.http.fail = true;
      h.storage.failWrites = true;
      expect(await statusOf(h.license), expiredOffline);
    });

    test('asks again on the next status(), the wait it could not save never started', () async {
      final h = await Harness.create();
      holding(h, await expired(h));
      h.http.fail = true;
      h.storage.failWrites = true;
      await h.license.status();
      await h.license.status();
      expect(validates(h), 2);
    });
  });

  group('the install keyed by the machine id it read', () {
    for (final status in <int?>[null, 503, 429, 403, 400]) {
      test('whatever the ask got back: ${status ?? 'no answer'}', () async {
        final h = await Harness.create(
            fingerprinter: ScriptedFingerprinter(const DeviceIdentity(fingerprint: 'fp-test', kind: DeviceKind.machine)));
        holding(h, await expired(h));
        if (status == null) {
          h.http.fail = true;
        } else {
          answers(h, status, {'error': status == 403 ? 'revoked' : 'unavailable'});
        }
        await h.license.refresh();
        expect(h.stored?.deviceKind, DeviceKind.machine);
        expect(h.stored?.backoffSince, now0);
      });
    }

    test('tells the server the kind with every fingerprint', () async {
      final h = await Harness.create(
          fingerprinter: ScriptedFingerprinter(
              const DeviceIdentity(fingerprint: 'fp-test', kind: DeviceKind.machine, alternates: ['fp-host'])));
      holding(h, await h.signer.lease(key1));
      answers(h, 503);
      await h.license.refresh();
      expect(h.http.bodyOf('validate')['fingerprints'], ['fp-test', 'fp-host']);
      expect(h.http.bodyOf('validate')['fingerprintKind'], 'machine');
    });
  });
}
