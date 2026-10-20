// status() offline-first, refresh() forced online, and test licences
// (license.test.ts 'status (offline-first)', 'refresh (forced online)',
// 'test licences'; StatusTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/harness.dart';
import '../support/status_support.dart';

/// A stored activation of `key1` whose lease ran out two days ago.
Future<String> expiredLease(Harness h) async {
  final expired = await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day);
  store(h, {'key': key1, 'activationId': 'act_1', 'lease': expired, 'lastSeen': now0});
  return expired;
}

void main() {
  group('status (offline-first)', () {
    test('is unlicensed with no state', () async {
      final h = await Harness.create();
      expect(await statusOf(h.license), {'state': 'unlicensed'});
    });

    test('is licensed from a valid lease without contacting the server', () async {
      final h = await Harness.create();
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': await h.signer.lease(key1), 'lastSeen': now0});
      final status = await h.license.status();
      expect(status.state, LicenseState.licensed);
      expect(h.http.calls, isEmpty);
    });

    test("licenses a typed key whose lease is a trial model's, offline, never as a device trial", () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1, model: 'trial'));
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
      await h.license.launchReportSettled();
      expect(h.http.calls, isEmpty);
      expect(h.stored?.trialLease, isNull);
    });

    test('treats an empty key or lease as none', () async {
      final h = await Harness.create();
      final trial = await h.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 86400);
      // Synced within the day, so no launch report is due either.
      store(h, {
        'key': '',
        'activationId': 'act_1',
        'lease': '',
        'trialStart': now0 - day,
        'trialEndsAt': now0 + day,
        'trialLease': trial,
        'trialAt': now0 - day ~/ 2,
      });
      expect(await statusOf(h.license), {'state': 'trial', 'trialDaysLeft': 1, 'trialEndsAt': now0 + day});
      await h.license.launchReportSettled();
      expect(h.http.calls, isEmpty);
    });

    test('renews online when the lease has expired', () async {
      final h = await Harness.create();
      await expiredLease(h);
      final fresh = await h.signer.lease(key1);
      answers(h, 200, {'lease': fresh, 'activationId': 'act_1'});
      expect(await statusOf(h.license), licensedJson);
      expect(h.http.called('validate'), isTrue);
      expect(h.stored?.lease, fresh);
    });

    test('stays expired offline when an expired lease cannot be renewed', () async {
      final h = await Harness.create();
      await expiredLease(h);
      h.http.fail = true;
      expect(await statusOf(h.license), expiredOffline);
    });

    for (final word in ['revoked', 'expired', 'deactivated']) {
      test('locks out when renewal returns the definitive $word', () async {
        final h = await Harness.create();
        await expiredLease(h);
        refuses(h, word);
        expect(await statusOf(h.license), invalid('revoked'));
      });
    }

    for (final (word, reason) in [('upgrade-required', 'upgrade'), ('update-required', 'outdated')]) {
      test('reports $reason when renewal says $word', () async {
        final h = await Harness.create();
        await expiredLease(h);
        refuses(h, word);
        expect(await statusOf(h.license), invalid(reason));
      });
    }

    for (final (name, status, json) in [
      ('an unverifiable lease', 200, {'lease': 'garbage.lease.value'}),
      ('a 200 with no lease', 200, <String, Object?>{}),
      ('a 200 that is no object', 200, null),
      ('a transient 5xx', 503, {'error': 'unavailable'}),
      ('a 429', 429, {'error': 'rate-limited'}),
      ('an ambiguous 4xx', 404, {'error': 'unknown-product'}),
      ('a 403 with a word it does not know', 403, {'error': 'something-new'}),
    ]) {
      test('falls back to expired offline on $name, never to a revocation', () async {
        final h = await Harness.create();
        final expired = await expiredLease(h);
        answers(h, status, json);
        expect(await statusOf(h.license), expiredOffline);
        expect(h.stored?.lease, expired);
        expect(h.stored?.refused, isNull);
      });
    }

    test('reports upgrade when the renewal lease covers a lower major than the app, and keeps it', () async {
      final h = await Harness.create(major: 2);
      await expiredLease(h);
      final freshMajor1 = await h.signer.lease(key1);
      answers(h, 200, {'lease': freshMajor1, 'activationId': 'act_1'});
      expect(await statusOf(h.license), invalid('upgrade'));
      expect(h.stored?.lease, freshMajor1);
    });

    test('reports tampered for a lease not signed by the product key, the server out of reach', () async {
      final h = await Harness.create();
      final other = await Signer.create();
      holding(h, await unnamedLease(other, key1));
      h.http.fail = true;
      expect(await statusOf(h.license), {'state': 'invalid', 'reason': 'tampered'});
    });

    test('lets the server heal a locally invalid lease', () async {
      final h = await Harness.create();
      final other = await Signer.create();
      holding(h, await unnamedLease(other, key1));
      final fresh = await h.signer.lease(key1);
      answers(h, 200, {'lease': fresh, 'activationId': 'act_1'});
      expect(await statusOf(h.license), licensedJson);
      expect(h.stored?.lease, fresh);
    });

    test('rejects a validly signed lease issued for a different product', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1, productSlug: 'other-app'));
      h.http.fail = true;
      expect(await statusOf(h.license), {'state': 'invalid', 'reason': 'tampered'});
    });

    test('reports upgrade offline when the app major exceeds the lease coverage', () async {
      final h = await Harness.create(major: 2);
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': await h.signer.lease(key1), 'lastSeen': now0});
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('upgrade'));
    });

    test('ignores a rolled-back clock: it cannot resurrect an expired lease', () async {
      final h = await Harness.create();
      final lease = await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day);
      // lastSeen is far ahead; a clock put back must not help.
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': lease, 'lastSeen': now0 + 10 * day});
      h.clock.value = now0 - 5 * day;
      h.http.fail = true;
      expect(await statusOf(h.license), expiredOffline);
    });

    test('is unknown, storage, when the state cannot be read, and asks nothing', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1));
      h.storage.failRead(1);
      final status = await h.license.status();
      expect(status.state, LicenseState.unknown);
      expect(status.reason, LicenseReason.storage);
      expect(h.http.calls, isEmpty);
      expect(await statusOf(h.license), licensedJson);
    });
  });

  group('refresh (forced online)', () {
    test('renews a still-valid lease and keeps it licensed', () async {
      final h = await Harness.create();
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': await h.signer.lease(key1), 'lastSeen': now0});
      final fresh = await h.signer.lease(key1, at: now0 + 1000);
      answers(h, 200, {'lease': fresh, 'activationId': 'act_1'});
      expect(await refreshOf(h.license), licensedJson);
      expect(h.http.called('validate'), isTrue);
      expect(h.stored?.lease, fresh);
    });

    test('keeps a valid lease licensed when the forced renewal cannot reach the server', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1));
      h.http.fail = true;
      expect(await refreshOf(h.license), licensedJson);
      expect(validates(h), 1);
    });

    for (final (name, status) in [('a transient 5xx', 500), ('a 429 rate limit', 429), ('an ambiguous 4xx', 404)]) {
      test('keeps a valid lease licensed on $name', () async {
        final h = await Harness.create();
        holding(h, await h.signer.lease(key1));
        answers(h, status, {'error': 'boom'});
        expect(await refreshOf(h.license), licensedJson);
      });
    }

    test('sends the body the contract names, bounded by the configured timeout', () async {
      final h = await Harness.create(httpTimeout: const Duration(seconds: 7));
      holding(h, await h.signer.lease(key1));
      answers(h, 503);
      await h.license.refresh();
      final body = h.http.bodyOf('validate');
      expect(body['key'], key1);
      expect(body['activationId'], 'act_1');
      expect(body['major'], 1);
      expect(body['kids'], [h.signer.kid]);
      expect(h.http.calls.single.timeout, const Duration(seconds: 7));
    });

    test('asks nothing on a device holding no licence', () async {
      final h = await Harness.create();
      expect(await refreshOf(h.license), {'state': 'unlicensed'});
      expect(h.http.calls, isEmpty);
    });
  });

  group('test licences', () {
    const testKey = 'SLUICE-TEST-TEST-TEST-TEST';
    Future<String> testLease(Harness h, {int ttlSeconds = 30 * 86400, int at = now0}) =>
        h.signer.lease(testKey, ttlSeconds: ttlSeconds, at: at, extra: {'test': true});

    Future<void> activated(Harness h, String lease) async {
      h.activates(lease);
      expect(await h.license.activate(testKey), isA<Activated>());
    }

    test('licenses the app, and says it is a test licence so a release build can refuse it', () async {
      final h = await Harness.create();
      await activated(h, await testLease(h));
      final status = await h.license.status();
      expect(status.test, isTrue);
      expect(js(status), {'state': 'licensed', 'key': testKey, 'test': true});
    });

    test('says nothing about it on a real licence', () async {
      final h = await Harness.create();
      await activated(h, await h.signer.lease(testKey));
      expect(await statusOf(h.license), {'state': 'licensed', 'key': testKey});
    });

    test('keeps saying so after a renewal of an expired lease', () async {
      final h = await Harness.create();
      await activated(h, await testLease(h, ttlSeconds: 60));
      final later = now0 + 2 * 3600000;
      h.clock.value = later;
      h.renews(await testLease(h, at: later));
      expect(await statusOf(h.license), {'state': 'licensed', 'key': testKey, 'test': true});
      expect(h.http.called('validate'), isTrue);
    });

    test('keeps saying so when a forced refresh cannot reach the server', () async {
      final h = await Harness.create();
      await activated(h, await testLease(h));
      h.http.fail = true;
      expect(await refreshOf(h.license), {'state': 'licensed', 'key': testKey, 'test': true});
      expect([for (final c in h.http.calls) c.action], ['activate', 'validate']);
    });
  });
}
