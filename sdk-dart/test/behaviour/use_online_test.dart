// use(meter, n) when the server answers, what a call asks for, and when it is
// not licensed (the SDK contract, section 12; use.test.ts, UseOnlineTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/meters.dart' show maxMeterUses;

import '../support/files_support.dart';
import '../support/harness.dart';
import '../support/meter_support.dart';

const verdicts = [
  ('revoked', UseError.revoked, Refusal.revoked),
  ('expired', UseError.revoked, Refusal.revoked),
  ('deactivated', UseError.revoked, Refusal.revoked),
  ('upgrade-required', UseError.upgrade, Refusal.upgrade),
  ('update-required', UseError.outdated, Refusal.outdated),
  ('device', UseError.device, Refusal.device),
];

Future<void> expectNotLicensed(Harness h) async {
  expect(await h.license.use('exports'), useRefused(UseError.notLicensed));
  expect(h.http.count('use'), 0, reason: 'nothing is asked');
}

void main() {
  group('online', () {
    test('spends exactly, sending the key, the seat, the meter, the amount and a fresh id', () async {
      final h = await holding();
      h.http.on('use', (_) => spent(89, at: now0 + 1));
      expect(await h.license.use('exports', 1), spentLeft(89));
      final body = h.useBody();
      expect([body['key'], body['activationId'], body['meter'], body['n'], body['major']], [key1, 'act_1', 'exports', 1, 1]);
      expect((body['id'] as String).length, 22);
      expect(body['kids'], [h.signer.kid]);
      expect(body['fingerprints'], hasLength(1));
      expect(body.containsKey('spends') || body.containsKey('keptMajor'), isFalse);
      expect(h.stored?.meterFigures['exports'], const MeterFigure(left: 89, total: 100, offline: 10, resets: false, at: now0 + 1));
      expect(h.journal, isEmpty);
    });

    test('spends a batch whole in one request, and one use when no amount is given', () async {
      final h = await holding();
      h.http.on('use', (_) => spent(50));
      expect(await h.license.use('exports', 40), spentLeft(50));
      expect(h.useBody()['n'], 40);
      await h.license.use('exports');
      expect(h.useBody(1)['n'], 1);
      expect(h.http.count('use'), 2);
    });

    test('makes a new id for each call: two calls are two spends', () async {
      final h = await holding();
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      await h.license.use('exports');
      expect(h.useBody(0)['id'], isNot(h.useBody(1)['id']));
    });

    test('answers from the figure the server gave, net of what this device has not reported', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 3, longAgo)]);
      h.http.on('use', (_) => spent(80));
      expect(await h.license.use('exports'), spentLeft(77));
    });

    test('answers from the base figures when the server gave none for the meter', () async {
      final h = await holding();
      h.http.on('use', (_) => const HttpResponse(200, {'spent': true, 'meters': {}, 'at': now0}));
      expect(await h.license.use('exports'), spentLeft(90));
      h.http.on('use', (_) => const HttpResponse(200, {'spent': true}));
      expect(await h.license.use('exports'), spentLeft(90));
    });

    test('answers nothing left for a spend of a meter neither the lease nor the answer names', () async {
      final h = await holding();
      h.http.on('use', (_) => const HttpResponse(200, {'spent': true, 'meters': {}, 'at': now0}));
      expect(await h.license.use('credits'), spentLeft(0));
      expect(h.stored?.meterFigures, isEmpty);
      expect((await h.license.status()).meters['credits'], isNull);
    });

    test('keeps a figure the lease is newer than only until the lease is renewed', () async {
      final h = await holding();
      h.http.on('use', (_) => spent(70, at: now0 + 5000));
      await h.license.use('exports');
      expect((await h.license.status()).meters['exports']?.left, 70);
      final renewed = await meteredLease(h, met: {'exports': {'left': 60, 'total': 100, 'offline': 10}}, at: now0 + 10000);
      h.renews(renewed);
      h.clock.value = now0 + 10000;
      expect((await h.license.refresh()).meters['exports']?.left, 60);
      expect((await h.license.status()).meters['exports']?.left, 60);
    });

    test('answers used-up with what the server says is left, and spends nothing offline after', () async {
      final h = await holdingJournal([entry(SpendKind.unanswered, 2, longAgo, id: spendId('B'))]);
      h.http.on('use', (_) => HttpResponse(409, {
            'error': 'used-up', 'left': 1, 'at': now0,
            'meters': {'exports': {'left': 1, 'total': 100, 'offline': 10}},
            'spends': [{'id': spendId('B'), 'n': 2}],
          }));
      expect(await h.license.use('exports', 5), useRefused(UseError.usedUp, 1));
      expect(h.journal, isEmpty);
      expect(h.stored?.meterFigures['exports']?.left, 1);
      h.http.fail = true;
      h.clock.value = now0 + 2 * minute;
      expect(await h.license.use('exports', 2), useRefused(UseError.offlineLimit, 1));
    });

    test('answers used-up with no left when the answer gave none', () async {
      final h = await holding();
      h.http.on('use', (_) => const HttpResponse(409, {'error': 'used-up'}));
      expect(await h.license.use('exports'), useRefused(UseError.usedUp));
    });

    test("reads the server's words on any status but a 200, a 5xx and a 429", () async {
      final h = await holding();
      h.http.on('use', (_) => const HttpResponse(400, {'error': 'used-up', 'left': 0}));
      expect(await h.license.use('exports'), useRefused(UseError.usedUp, 0));
      h.http.on('use', (_) => const HttpResponse(200, {'error': 'used-up', 'left': 0}));
      expect(await h.license.use('exports'), isA<UseSpent>().having((r) => r.offline, 'offline', isTrue));
      for (final status in [500, 503, 429]) {
        h.http.on('use', (_) => HttpResponse(status, {'error': 'used-up', 'left': 0}));
        h.clock.value += 2 * hour;
        expect(await h.license.use('exports'), isA<UseSpent>().having((r) => r.offline, 'offline', isTrue), reason: '$status');
      }
    });

    test("answers no-meter for a meter the server does not know, and confirms the reports it carried", () async {
      final h = await holdingJournal([entry(SpendKind.unanswered, 1, longAgo, id: spendId('C'))]);
      h.http.on('use', (_) => HttpResponse(404, {'error': 'unknown-meter', 'spends': [{'id': spendId('C'), 'n': 1}]}));
      expect(await h.license.use('exports'), useRefused(UseError.noMeter));
      expect(h.journal, isEmpty);
    });

    test("stores a verdict as a validate's is, and answers it as status will", () async {
      for (final (word, error, refusal) in verdicts) {
        final h = await holding();
        h.http.on('use', (_) => HttpResponse(403, {'error': word}));
        expect(await h.license.use('exports'), useRefused(error), reason: word);
        expect(h.stored?.refused, refusal, reason: word);
        final status = await h.license.status();
        expect([status.state, status.reason], [LicenseState.invalid, refusal.reason], reason: word);
        expect(await h.license.use('exports'), useRefused(UseError.notLicensed), reason: word);
        expect(h.http.count('use'), 1, reason: word);
      }
    });

    test('records the reports a verdict confirms', () async {
      final h = await holdingJournal([entry(SpendKind.void_, 1, longAgo, id: spendId('D'))]);
      h.http.on('use', (_) => HttpResponse(403, {'error': 'revoked', 'spends': [{'id': spendId('D'), 'void': true}]}));
      await h.license.use('exports');
      expect(h.journal, isEmpty);
    });

    test('a used-up meter refuses spends, never the licence nor an entitlement', () async {
      final h = await Harness.create();
      h.stored = StoredState.fromJson({
        'key': key1, 'activationId': 'act_1', 'lastSeen': now0,
        'lease': await meteredLease(h, over: {'ent': {'edition': 'pro'}}),
      });
      h.http.on('use', (_) => const HttpResponse(409, {
            'error': 'used-up', 'left': 0, 'at': now0,
            'meters': {'exports': {'left': 0, 'total': 100, 'offline': 10}},
          }));
      expect(await h.license.use('exports'), useRefused(UseError.usedUp, 0));
      final status = await h.license.status();
      expect(status.state, LicenseState.licensed);
      expect(status.meters['exports']?.left, 0);
      expect(await h.license.has('edition'), isTrue);
      await h.license.require('edition');
    });
  });

  group('the bound of the request', () {
    test('a use request waits five seconds for the server, or the HTTP bound when that is shorter', () async {
      final h = await holding();
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      expect(h.http.calls.single.timeout, const Duration(seconds: 5));
      final short = await holding(httpTimeout: const Duration(seconds: 1));
      short.http.on('use', (_) => spent(89));
      await short.license.use('exports');
      expect(short.http.calls.single.timeout, const Duration(seconds: 1));
    });

    test('a request that never answers is given up at its bound, and the spend comes from the allowance', () async {
      final h = await holding(httpTimeout: const Duration(milliseconds: 300));
      h.http.hang = true;
      final clock = Stopwatch()..start();
      expect(await h.license.use('exports'), spentLeft(89, offline: true));
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(290));
      expect(kindsAndCounts(h.journal), ['unanswered 1']);
    });
  });

  group('what is asked', () {
    test('refuses an amount that is not a whole number from 1 to the bound, asking nothing', () async {
      final h = await holding();
      for (final n in [0, -1, maxMeterUses + 1, 1 << 62, -(1 << 62)]) {
        expect(await h.license.use('exports', n), useRefused(UseError.invalidAmount), reason: '$n');
      }
      expect(h.http.count('use'), 0);
      expect(h.journal, isEmpty);
    });

    test('takes the bound itself', () async {
      final h = await holding(met: {'exports': {'left': 2000000000, 'total': 2000000000, 'offline': 0}});
      h.http.on('use', (_) => spent(1000000000));
      expect((await h.license.use('exports', maxMeterUses)).ok, isTrue);
      expect(h.useBody()['n'], maxMeterUses);
    });

    test('judges the amount before the meter, and refuses a code of no meter, asking nothing', () async {
      final h = await holding();
      expect(await h.license.use('', 0), useRefused(UseError.invalidAmount));
      for (final code in ['', 'x' * 33, '\u{1F600}' * 17]) {
        expect(await h.license.use(code), useRefused(UseError.noMeter), reason: code);
      }
      expect(h.http.count('use'), 0);
    });

    test('takes a code of 32 UTF-16 units, a surrogate pair at the edge, and matches it exactly', () async {
      final code = '${'x' * 30}\u{1F600}';
      expect(code.length, 32);
      const figure = {'left': 9, 'total': 9, 'offline': 0};
      final h = await holding(met: {code: figure, 'exports': figure});
      h.http.on('use', (_) => const HttpResponse(200, {'spent': true}));
      expect((await h.license.use(code)).ok, isTrue);
      expect(h.useBody()['meter'], code);
      h.http.fail = true;
      h.clock.value = now0 + 5 * minute;
      expect(await h.license.use('EXPORTS'), useRefused(UseError.noMeter));
    });

    test("spends a meter named like an object's member only when the key has it", () async {
      final h = await holding(met: {'constructor': {'left': 9, 'total': 9, 'offline': 3}});
      h.http.fail = true;
      expect((await h.license.use('constructor')).ok, isTrue);
      expect(await h.license.use('toString'), useRefused(UseError.noMeter));
      expect(await h.license.use('__proto__'), useRefused(UseError.noMeter));
    });
  });

  group('when it is not licensed', () {
    test('with no licence, an expired lease, a lease of another activation, and a trial, asking nothing', () async {
      await expectNotLicensed(await Harness.create());
      final expired = await holding();
      expired.clock.value = now0 + 40 * day;
      expired.http.fail = true;
      await expectNotLicensed(expired);
      final tampered = await Harness.create();
      tampered.hold(await meteredLease(tampered, over: {'aid': 'act_other'}), {'lastSeen': now0});
      await expectNotLicensed(tampered);
      final trial = await Harness.create();
      final lease = await trial.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 7 * 86400, extra: {'met': usualMeters});
      trial.stored = StoredState.fromJson({'trialStart': now0, 'trialEndsAt': now0 + 7 * day, 'trialLease': lease, 'lastSeen': now0});
      expect((await trial.license.status()).state, LicenseState.trial);
      await expectNotLicensed(trial);
    });

    test('with a stored refusal that stands, and for a build the lease does not cover', () async {
      await expectNotLicensed(await holding(state: {'refused': 'revoked'}));
      final newer = await holding(major: 4);
      newer.http.fail = true;
      await expectNotLicensed(newer);
    });

    test('with an offline licence file, which has no meters, even one carrying a met claim', () async {
      final h = await Harness.create();
      await h.license.importLicenseFile(fileText(await offlineFile(h, {'met': usualMeters})));
      final status = await h.license.status();
      expect([status.state, status.source], [LicenseState.licensed, LicenseSource.file]);
      expect(status.meters, isEmpty);
      await expectNotLicensed(h);
    });

    test('answers storage when the state cannot be read just now, asking nothing, and spends once it can', () async {
      final h = await holding();
      h.storage.failRead(1);
      expect(await h.license.use('exports'), useRefused(UseError.storage));
      expect(h.http.count('use'), 0);
      h.http.on('use', (_) => spent(89));
      expect(await h.license.use('exports'), spentLeft(89));
    });
  });

  group('an adapter that throws', () {
    test('a clock that throws answers storage, never an exception', () async {
      final h = await holding();
      final app = KeyGrantLicense(LicenseConfig(
        product: product,
        apiBaseUrl: h.config.apiBaseUrl,
        publicJwk: h.signer.publicJwk,
        adapters: LicenseAdapters(storage: h.storage, registry: h.stash, clock: ThrowingClock(), fingerprinter: const PlainFingerprinter(), http: h.http),
      ));
      expect(await app.use('exports'), useRefused(UseError.storage));
    });

    test('a request that throws, even before it is sent, is no answer: the allowance serves', () async {
      final h = await holding();
      final app = KeyGrantLicense(LicenseConfig(
        product: product,
        apiBaseUrl: h.config.apiBaseUrl,
        publicJwk: h.signer.publicJwk,
        adapters: LicenseAdapters(storage: h.storage, registry: h.stash, clock: h.clock, fingerprinter: const PlainFingerprinter(), http: ThrowingHttp()),
      ));
      expect(await app.use('exports'), spentLeft(89, offline: true));
    });
  });

  group('the device', () {
    test('names the device as a validate does its fingerprints', () async {
      final h = await holding();
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      await h.license.refresh();
      final validate = h.http.lastBodyOf('validate');
      for (final name in ['key', 'activationId', 'major', 'fingerprints']) {
        expect(h.useBody()[name], validate[name], reason: name);
      }
    });

    test('sends no fingerprints when devices are not held', () async {
      final h = await holding(deviceHold: false);
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      expect(h.useBody().containsKey('fingerprints') || h.useBody().containsKey('fingerprintKind'), isFalse);
    });

    test('sends the machine kind of a device that reads a machine id, and its alternates', () async {
      final h = await holding(fingerprinter: ScriptedFingerprinter(const DeviceIdentity(fingerprint: 'fp-machine', kind: DeviceKind.machine)));
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      expect([h.useBody()['fingerprintKind'], h.useBody()['fingerprints']], ['machine', ['fp-machine']]);
      final alt = await holding(
          fingerprinter: ScriptedFingerprinter(
              const DeviceIdentity(fingerprint: 'fp-machine', kind: DeviceKind.machine, alternates: ['fp-host'])));
      alt.http.on('use', (_) => spent(89));
      await alt.license.use('exports');
      expect(alt.useBody()['fingerprints'], hasLength(2));
    });

    test('sends no fingerprints when the device cannot be told', () async {
      final h = await holding(fingerprinter: const BlindFingerprinter());
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      expect(h.http.count('use'), 1);
      expect(h.useBody().containsKey('fingerprints'), isFalse);
    });
  });
}

final class ThrowingClock implements LicenseClock {
  @override
  int now() => throw StateError('the clock');
}

/// An HTTP adapter whose post throws before it returns a future.
final class ThrowingHttp implements HttpAdapter {
  @override
  Future<HttpResponse> post(String url, Map<String, Object?> body, {required Duration timeout}) => throw StateError('the adapter');
}
