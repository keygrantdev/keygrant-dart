// Entitlements on a status, and has() / require() (license.test.ts
// 'entitlements', key-set.test.ts 'has and require'; EntitlementTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/lease.dart' show openMajor;

import '../support/harness.dart';
import '../support/status_support.dart';

const entKey = 'SLUICE-ENTL-ENTL-ENTL-ENTL';
const pro = {'edition': 'pro', 'seats': 5, 'beta': false};
const quick = Timing(lockGrace: Duration(milliseconds: 40));

/// A lease for `entKey` over any claims, `ent` included as given.
Future<String> signedWith(Harness h, Map<String, Object?> over, {int at = now0}) =>
    h.signer.lease(entKey, at: at, extra: over);

Future<void> activated(Harness h, String lease) async {
  h.activates(lease);
  expect(await h.license.activate(entKey), isA<Activated>());
}

void storeEnt(Harness h, String lease, [Map<String, Object?> more = const {}]) =>
    store(h, {'key': entKey, 'activationId': 'act_1', 'lease': lease, 'checkedMajor': 1, 'lastSeen': now0, ...more});

Map<String, Object?> licensedWith(Map<String, Object?> ent, {bool test = false}) =>
    {'state': 'licensed', 'key': entKey, if (test) 'test': true, 'entitlements': ent};

void main() {
  group('entitlements', () {
    test('hands the app what the lease grants, once activated', () async {
      final h = await Harness.create();
      await activated(h, await signedWith(h, {'ent': pro}));
      final status = await h.license.status();
      expect(js(status), licensedWith(pro));
      expect(status.entitlements['edition'], const TextEntitlement('pro'));
      expect(status.entitlements['seats'], const NumberEntitlement(5));
      expect(status.entitlements['beta'], const FlagEntitlement(false));
    });

    test('says nothing of them when the lease grants none: empty, and absent from the JSON', () async {
      final h = await Harness.create();
      await activated(h, await signedWith(h, {'ent': <String, Object?>{}}));
      final status = await h.license.status();
      expect(status.entitlements, isEmpty);
      expect(js(status), {'state': 'licensed', 'key': entKey});
    });

    test('keeps the good members of a malformed ent, and the licence it rides on', () async {
      final h = await Harness.create();
      storeEnt(h, await signedWith(h, {
        'ent': {'edition': 'pro', 'nested': {'tier': 'gold'}, 'none': null, 'list': [1], 'seats': 2},
      }));
      expect(await statusOf(h.license), licensedWith({'edition': 'pro', 'seats': 2}));
    });

    test('reads an ent that is not an object as none, never as a refusal', () async {
      final h = await Harness.create();
      for (final ent in [['pro'], 'pro', 7]) {
        storeEnt(h, await signedWith(h, {'ent': ent}));
        expect(await statusOf(h.license), {'state': 'licensed', 'key': entKey}, reason: '$ent');
      }
    });

    test('takes them from the renewed lease, not the one it replaced', () async {
      final h = await Harness.create();
      await activated(h, await signedWith(h, {'ent': {'edition': 'basic'}, 'exp': now0 ~/ 1000 + 60}));
      final later = now0 + 2 * 3600000;
      h.clock.value = later;
      h.renews(await signedWith(h, {'ent': pro}, at: later));
      expect(await statusOf(h.license), licensedWith(pro));
      expect(h.http.called('validate'), isTrue);
    });

    test("refresh(): the new lease's when the server answers, the held lease's when it cannot", () async {
      final h = await Harness.create();
      await activated(h, await signedWith(h, {'ent': {'edition': 'basic'}}));
      h.renews(await signedWith(h, {'ent': pro}));
      expect(await refreshOf(h.license), licensedWith(pro));
      h.http.fail = true;
      expect(await refreshOf(h.license), licensedWith(pro));
      expect([for (final c in h.http.calls) c.action], ['activate', 'validate', 'validate']);
    });

    test("carries a test licence's beside its test flag", () async {
      final h = await Harness.create();
      await activated(h, await signedWith(h, {'ent': pro, 'test': true}));
      expect(await statusOf(h.license), licensedWith(pro, test: true));
    });

    test('carries none on a status that does not license, though the lease grants them', () async {
      final h = await Harness.create(major: 2);
      h.http.fail = true;
      store(h, {'key': entKey, 'activationId': 'act_1', 'lease': await signedWith(h, {'ent': pro}), 'lastSeen': now0});
      expect(await statusOf(h.license), invalid('upgrade', entKey));
      final ended = await signedWith(h, {'ent': pro, 'major': 2, 'exp': now0 ~/ 1000 - 1});
      store(h, {'key': entKey, 'activationId': 'act_1', 'lease': ended, 'lastSeen': now0});
      expect(await statusOf(h.license), {'state': 'expired', 'reason': 'offline', 'key': entKey});
      final another = await signedWith(h, {'ent': pro, 'major': 2, 'sub': 'SLUICE-ZZZZ-ZZZZ-ZZZZ-ZZZZ'});
      store(h, {'key': entKey, 'activationId': 'act_1', 'lease': another, 'lastSeen': now0});
      expect(await statusOf(h.license), {'state': 'invalid', 'reason': 'tampered'});
    });

    test('carries none on a refusal the server gave, though the lease it keeps grants them', () async {
      final h = await Harness.create();
      await activated(h, await signedWith(h, {'ent': pro}));
      refuses(h, 'upgrade-required');
      expect(await refreshOf(h.license), invalid('upgrade', entKey));
      expect(h.stored?.lease, isNotNull);
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('upgrade', entKey));
    });

    test('carries none on a stored refusal answered behind a call that has not finished', () async {
      final h = await Harness.create(httpTimeout: const Duration(milliseconds: 40), timing: quick);
      storeEnt(h, await signedWith(h, {'ent': pro}), {'refused': 'upgrade', 'refusedMajor': 1});
      h.storage.hangNextRead = true;
      h.license.status().ignore();
      expect(await statusOf(h.license), {...invalid('upgrade', entKey), 'stalled': true});
    });

    test('still carries them behind a call that has not finished, from the lease held', () async {
      final h = await Harness.create(httpTimeout: const Duration(milliseconds: 40), timing: quick);
      storeEnt(h, await signedWith(h, {'ent': pro}));
      h.storage.hangNextRead = true;
      h.license.status().ignore();
      expect(await statusOf(h.license), {...licensedWith(pro), 'stalled': true});
    });

    test("keeps the held lease's when an early renewal gets no answer", () async {
      final h = await Harness.create();
      final lease = await signedWith(h, {'ent': pro, 'iat': now0 ~/ 1000 - 25 * 86400, 'exp': now0 ~/ 1000 + 5 * 86400});
      storeEnt(h, lease);
      h.http.fail = true;
      expect(await statusOf(h.license), licensedWith(pro));
      expect([for (final c in h.http.calls) c.action], ['validate']);
    });

    test("hands a trial the trial lease's, from startTrial() and every status() after", () async {
      final h = await Harness.create();
      final trialLease = await h.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 5 * 86400, extra: {'ent': pro});
      h.http.on('trial', (_) => HttpResponse(200, {'trialStart': now0 - 2 * day, 'trialEndsAt': now0 + 5 * day, 'lease': trialLease}));
      final trial = {'state': 'trial', 'trialDaysLeft': 5, 'trialEndsAt': now0 + 5 * day, 'entitlements': pro};
      expect(js(await h.license.startTrial()), trial);
      h.http.fail = true;
      expect(await statusOf(h.license), trial);
    });

    test('gives a trial none once its lease no longer runs it', () async {
      final h = await Harness.create();
      final trialLease = await h.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 86400, extra: {'ent': pro});
      store(h, {'trialStart': now0 - 6 * day, 'trialEndsAt': now0 + day, 'trialLease': trialLease, 'lastSeen': now0});
      h.clock.value = now0 + 2 * day;
      h.http.fail = true;
      expect(await statusOf(h.license), {'state': 'expired', 'reason': 'trial'});
    });

    test('cannot be changed through a status: the next status is as the lease says', () async {
      final h = await Harness.create();
      storeEnt(h, await signedWith(h, {'ent': pro}));
      final first = await h.license.status();
      try {
        first.entitlements['edition'] = const TextEntitlement('studio');
      } on UnsupportedError {
        // Read-only: as good as a copy the app owns.
      }
      expect(js(await h.license.status()), licensedWith(pro));
    });
  });

  group('has and require', () {
    const ent = {'cloud': true, 'beta': false, 'seats': 0, 'devices': 5, 'edition': 'pro', 'blank': ''};

    Future<Harness> licensed() async {
      final h = await Harness.create();
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': await h.signer.lease(key1, extra: {'ent': ent})});
      return h;
    }

    test('answers from the stored lease: a flag on, a number not zero, a text not empty', () async {
      final h = await licensed();
      final answers = {for (final code in [...ent.keys, 'export', 'constructor', 'Cloud']) code: await h.license.has(code)};
      expect(answers, {
        'cloud': true,
        'beta': false,
        'seats': false,
        'devices': true,
        'edition': true,
        'blank': false,
        'export': false,
        'constructor': false,
        'Cloud': false,
      });
    });

    test('never goes online and never writes', () async {
      final h = await licensed();
      // A lease near its end, which status() would renew.
      h.clock.value = now0 + 29 * day;
      final writes = h.storage.writes;
      expect(await h.license.has('cloud'), isTrue);
      expect(h.http.calls, isEmpty);
      expect(h.storage.writes, writes);
    });

    test('grants nothing on a lease that does not license this build, nor with no licence', () async {
      final h = await licensed();
      h.clock.value = now0 + 31 * day;
      expect(await h.license.has('cloud'), isFalse);
      h.stored = null;
      expect(await h.license.has('cloud'), isFalse);
    });

    test('grants nothing over a stored refusal, though the lease it kept still verifies', () async {
      final h = await licensed();
      final lease = h.stored!.lease!;
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': lease, 'refused': 'upgrade', 'refusedMajor': 1});
      expect(await h.license.has('cloud'), isFalse);
      store(h, {'key': key1, 'activationId': 'act_1', 'lease': lease, 'refused': 'revoked'});
      expect(await h.license.has('cloud'), isFalse);
    });

    test('grants, during a running trial, what its trial lease signs', () async {
      final h = await Harness.create();
      final claim = fingerprintClaim('fp-test');
      final trialLease = await h.signer.lease('trial:$claim',
          aid: claim, model: 'trial', ttlSeconds: 7 * 86400, major: openMajor, extra: {'fpk': 'machine', 'lim': 1, 'ent': {'cloud': true}});
      store(h, {'trialStart': now0, 'trialLease': trialLease, 'lastSeen': now0});
      expect(await h.license.has('cloud'), isTrue);
      expect(await h.license.has('export'), isFalse);
      expect(h.http.calls, isEmpty);
      expect((await h.license.status()).state, LicenseState.trial);
    });

    test('grants nothing, without throwing, while the state cannot be read', () async {
      final h = await licensed();
      h.storage.failRead(1);
      expect(await h.license.has('cloud'), isFalse);
    });

    test('require completes for a granted code and throws naming the code otherwise', () async {
      final h = await licensed();
      await h.license.require('cloud');
      await expectLater(
          h.license.require('seats'), throwsA(isA<MissingEntitlement>().having((e) => e.entitlement, 'entitlement', 'seats')));
    });
  });
}
