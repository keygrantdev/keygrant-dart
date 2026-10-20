// deactivate() (the SDK contract, 5.5; license.test.ts `deactivate`, and the
// release of another device's seat; meter-reports.test.ts, what a deactivate reports).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/keys.dart' show fingerprintClaim;

import '../support/harness.dart';
import '../support/trials_support.dart';

const _ok = HttpResponse(200, {'ok': true});

/// A 30-day lease of `key1`, held to `device` by a machine id (none: held to no machine).
Future<String> leaseFor(Harness h, {String? device = 'fp-test', int at = now0}) => h.signer.lease(key1,
    at: at, extra: device == null ? const {} : {'fp': fingerprintClaim(device), 'fpk': 'machine'});

/// A metered lease, and a journal entry of `exports`.
Future<String> meteredLease(Harness h) => h.signer.lease(key1, model: 'subscription', major: 3, extra: {
      'met': {
        'exports': {'left': 90, 'total': 100, 'offline': 10},
      },
    });

Map<String, Object?> entry({String id = 'AAAAAAAAAAAAAAAAAAAAAA', String kind = 'offline'}) =>
    {'id': id, 'meter': 'exports', 'n': 1, 'at': now0, 'kind': kind};

void main() {
  group('deactivate', () {
    test('releases the activation and clears the licence held here', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer));
      h.http.on('deactivate', (_) => _ok);
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.called('deactivate'), isTrue);
      expect(h.stored!.key, isNull);
      expect((await h.license.status()).state, LicenseState.unlicensed);
    });

    test('clears the licence even when the server cannot be reached, and says the seat may still be held', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer));
      h.http.fail = true;
      expect((await h.license.deactivate()).released, isFalse);
      expect(h.stored!.key, isNull);
      expect((await h.license.status()).state, LicenseState.unlicensed);
    });

    test('takes only a 200 as the seat released, dropping the licence all the same', () async {
      for (final answer in [
        const HttpResponse(503, {'error': 'internal'}),
        const HttpResponse(429, {'error': 'rate-limited'}),
        const HttpResponse(403, '<html>blocked by policy</html>'),
      ]) {
        final h = await Harness.create();
        storeJson(h, await licensedJson(h.signer));
        h.http.on('deactivate', (_) => answer);
        expect((await h.license.deactivate()).released, isFalse);
        expect(h.stored!.key, isNull);
      }
    });

    test('asks nothing, and answers released, with no activation held', () async {
      final h = await Harness.create();
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.called('deactivate'), isFalse);
      expect((await h.license.status()).state, LicenseState.unlicensed);
    });

    test('keeps the trial evidence', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, await runningTrial(h.signer)));
      h.http.on('deactivate', (_) => _ok);
      await h.license.deactivate();
      expect(h.stored!.trialStart, now0 - 2 * day);
      expect(h.stored!.trialLease, isNotNull);
    });

    test('stamps the deactivation by the guarded clock', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {'lastSeen': now0 + 5 * 60000}));
      h.http.on('deactivate', (_) => _ok);
      h.clock.value = now0 - day;
      await h.license.deactivate();
      expect(h.stored!.verdictAt, now0 + 5 * 60000);
    });
  });

  group("deactivate, when the activation stored is another device's", () {
    test("drops it here without releasing that device's seat", () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {'lease': await leaseFor(h, device: 'fp-other-pc')}));
      h.http.on('deactivate', (_) => _ok);
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.called('deactivate'), isFalse);
      expect(h.stored!.key, isNull);
    });

    test('reads whose seat it is from a lease that has run out too', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {'lease': await leaseFor(h, device: 'fp-other-pc', at: now0 - 40 * day)}));
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.called('deactivate'), isFalse);
    });

    test('takes a device refusal that stands for this device as the same', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {
        'lease': await leaseFor(h),
        'refused': 'device',
        'refusedFor': [fingerprintClaim('fp-test')],
      }));
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.called('deactivate'), isFalse);
    });

    test("still releases this device's own seat, and one held to no machine", () async {
      for (final device in ['fp-test', null]) {
        final h = await Harness.create();
        storeJson(h, await licensedJson(h.signer, {'lease': await leaseFor(h, device: device)}));
        h.http.on('deactivate', (_) => _ok);
        expect((await h.license.deactivate()).released, isTrue);
        expect(h.http.called('deactivate'), isTrue, reason: '$device');
      }
    });
    test('releases the seat on a run that cannot tell who the device is', () async {
      final h = await Harness.create(fingerprinter: const FailingFingerprinter());
      storeJson(h, await licensedJson(h.signer, {'lease': await leaseFor(h, device: 'fp-other-pc')}));
      h.http.on('deactivate', (_) => _ok);
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.called('deactivate'), isTrue);
    });
  });

  group('what a deactivate reports', () {
    test("carries the journal with the device's fingerprints, then clears it with the rest of the licence", () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {
        'lease': await meteredLease(h),
        'spends': [entry(), entry(id: 'BBBBBBBBBBBBBBBBBBBBBB', kind: 'void')],
      }));
      h.http.on('deactivate', (_) => _ok);
      expect((await h.license.deactivate()).released, isTrue);
      final body = h.http.bodyOf('deactivate');
      expect(body['key'], key1);
      expect(body['activationId'], 'act_1');
      expect(body['spends'], hasLength(2));
      expect(body['fingerprints'], ['fp-test']);
      expect(h.storedJson.containsKey('spends'), isFalse);
      expect(h.storedJson.containsKey('meterFigures'), isFalse);
      expect(h.stored!.activationId, isNull);
    });

    test('sends exactly the key and the activation when there is nothing to report', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer));
      h.http.on('deactivate', (_) => const HttpResponse(200, {}));
      await h.license.deactivate();
      expect(h.http.bodyOf('deactivate'), {'key': key1, 'activationId': 'act_1'});
    });

    test('names no fingerprints when it cannot tell who the device is', () async {
      final h = await Harness.create(fingerprinter: const FailingFingerprinter());
      storeJson(h, await licensedJson(h.signer, {'lease': await meteredLease(h), 'spends': [entry()]}));
      h.http.on('deactivate', (_) => const HttpResponse(200, {}));
      await h.license.deactivate();
      expect(h.http.bodyOf('deactivate')['spends'], hasLength(1));
      expect(h.http.bodyOf('deactivate').containsKey('fingerprints'), isFalse);
    });

    test('reports what this process could not save, and forgets it with the rest', () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {'lease': await meteredLease(h)}));
      h.http.fail = true;
      h.storage.failWrites = true;
      expect(await h.license.use('exports'), isA<UseSpent>());
      h.storage.failWrites = false;
      h.http.fail = false;
      h.http.on('deactivate', (_) => const HttpResponse(200, {}));
      await h.license.deactivate();
      expect(h.http.bodyOf('deactivate')['spends'], hasLength(1));
      h.activates(await meteredLease(h));
      await h.license.activate(key1);
      expect((await h.license.status()).meters['exports']?.unsynced, 0);
      expect(h.storedJson.containsKey('spends'), isFalse);
    });

    test("reports nothing for a seat that is another device's", () async {
      final h = await Harness.create();
      storeJson(h, await licensedJson(h.signer, {'lease': await leaseFor(h, device: 'fp-other-pc'), 'spends': [entry()]}));
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.count('deactivate'), 0);
    });
  });
}
