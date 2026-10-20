// A lease held to its key, its activation and its device; the server's device
// refusal; and deviceHold false (license.test.ts 'a lease held to its key,
// its activation and its device', 'who this device is, when it cannot be
// told'; DeviceTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/offline.dart' show retryUnansweredMs;

import '../support/harness.dart';
import '../support/status_support.dart';

ScriptedFingerprinter machine(String fingerprint, [List<String> alternates = const []]) =>
    ScriptedFingerprinter(DeviceIdentity(fingerprint: fingerprint, kind: DeviceKind.machine, alternates: alternates));

void main() {
  group('a lease held to its device', () {
    test('licenses this device on its own lease, offline', () async {
      final h = await Harness.create();
      holding(h, await machineLease(h));
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
      expect(validates(h), 0);
    });

    test('takes a lease with no device claim, which its renewal brings', () async {
      final h = await Harness.create();
      holding(h, await machineLease(h, device: null));
      h.http.fail = true;
      expect((await h.license.status()).state, LicenseState.licensed);
    });

    test('matches the key without regard to case, as the server does', () async {
      final h = await Harness.create();
      holding(h, await machineLease(h, sub: 'Sluice-aaaa-BBBB-CCCC-DDDD'));
      h.http.fail = true;
      expect((await h.license.status()).state, LicenseState.licensed);
    });

    test('does not judge a lease whose seat is keyed by a host name', () async {
      final h = await Harness.create();
      holding(h, await h.signer.lease(key1, extra: {'fp': fingerprintClaim('old-name'), 'fpk': 'hostname'}));
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
    });

    for (final (name, lease, refused) in <(String, Future<String> Function(Harness), Map<String, Object?>)>[
      ('another key', (h) => machineLease(h, sub: 'SLUICE-OTHR-OTHR-OTHR-OTHR'), {'state': 'invalid', 'reason': 'tampered'}),
      ('another activation', (h) => machineLease(h, aid: 'act_2'), {'state': 'invalid', 'reason': 'tampered'}),
      ('another device', (h) => machineLease(h, device: 'fp-another-machine'), invalid('device')),
    ]) {
      test('refuses offline a lease for $name, and asks the server under the usual waits', () async {
        final h = await Harness.create();
        holding(h, await lease(h));
        h.http.fail = true;
        expect(await statusOf(h.license), refused);
        expect(validates(h), 1);
        expect(await statusOf(h.license), refused);
        expect(validates(h), 1);
        h.clock.value = now0 + retryUnansweredMs;
        await h.license.status();
        expect(validates(h), 2);
      });
    }

    test("stays refused for another device even online: the server renews the other device's lease", () async {
      final h = await Harness.create();
      final theirs = await machineLease(h, device: 'fp-another-machine');
      holding(h, theirs);
      h.renews(theirs);
      expect(await statusOf(h.license), invalid('device'));
      expect(await refreshOf(h.license), invalid('device'));
    });

    test("says device, offline too, once a lease with no device claim is renewed with another device's", () async {
      final h = await Harness.create();
      holding(h, await machineLease(h, device: null));
      h.renews(await machineLease(h, device: 'fp-another-machine'));
      expect(await refreshOf(h.license), invalid('device'));
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('device'));
    });

    test('accepts the lease an activation of this device is given, and refuses one for another device', () async {
      final h = await Harness.create();
      h.activates(await machineLease(h));
      expect(await h.license.activate(key1), isA<Activated>());
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);

      final other = await Harness.create();
      other.activates(await machineLease(other, device: 'fp-another-machine'));
      final result = await other.license.activate(key1);
      expect(result, isA<ActivateFailed>().having((r) => r.error, 'error', LicenseError.invalidLease));
    });
  });

  group("the server's device refusal", () {
    test('is taken for this device only, the lease kept', () async {
      final h = await Harness.create();
      holding(h, await machineLease(h));
      refuses(h, 'device');
      expect(await refreshOf(h.license), invalid('device'));
      expect(h.http.bodyOf('validate')['fingerprints'], ['fp-test']);
      // A get()-only fingerprinter says nothing of what it hashes: no kind is claimed for it.
      expect(h.http.bodyOf('validate').containsKey('fingerprintKind'), isFalse);
      expect(h.stored?.refused, Refusal.device);
      expect(h.stored?.refusedFor, [fingerprintClaim('fp-test')]);
      expect(h.stored?.lease, isNotNull);
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('device'));
    });

    test('licenses again at once when the fingerprint flips back', () async {
      final fingerprinter = ScriptedFingerprinter(const DeviceIdentity(fingerprint: 'fp-flipped'));
      final h = await Harness.create(fingerprinter: fingerprinter);
      holding(h, await machineLease(h));
      refuses(h, 'device');
      expect((await h.license.refresh()).reason, LicenseReason.device);
      // The next run reads the device as it was: the refusal was not for it.
      fingerprinter.identity = const DeviceIdentity(fingerprint: 'fp-test');
      h.http.fail = true;
      expect(await statusOf(h.licenseFor(1)), licensedJson);
    });

    test('does not stand on a later run that only shares its host-name alternate', () async {
      final fingerprinter = machine('fp-boot-1', ['fp-same-host']);
      final h = await Harness.create(fingerprinter: fingerprinter);
      // A lease whose seat's kind is unknown: not itself judged by its device.
      holding(h, await h.signer.lease(key1));
      refuses(h, 'device');
      expect((await h.license.refresh()).reason, LicenseReason.device);
      expect(h.stored?.refusedFor, [fingerprintClaim('fp-boot-1')]);
      fingerprinter.identity = const DeviceIdentity(fingerprint: 'fp-boot-2', kind: DeviceKind.machine, alternates: ['fp-same-host']);
      h.http.fail = true;
      expect(await statusOf(h.licenseFor(1)), licensedJson);
    });

    test('stands with no device it was given for, as an earlier version stored it', () async {
      final h = await Harness.create();
      holding(h, await machineLease(h), {'refused': 'device'});
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('device'));
    });

    test('is asked again once the wait is over, and heals on a lease for this device', () async {
      final h = await Harness.create();
      holding(h, await machineLease(h), {'refused': 'device', 'refusedFor': [fingerprintClaim('fp-test')]});
      h.renews(await machineLease(h));
      expect(await statusOf(h.license), licensedJson);
      expect(h.stored?.refused, isNull);
      expect(h.stored?.refusedFor, isNull);
    });
  });

  group('who this device is, when it cannot be told', () {
    test('neither judges the device nor tells the server who it is', () async {
      final h = await Harness.create(fingerprinter: ScriptedFingerprinter(const DeviceIdentity(fingerprint: null)));
      final elsewhere = await machineLease(h, device: 'fp-another-machine');
      holding(h, elsewhere);
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
      h.http.fail = false;
      h.renews(elsewhere);
      expect(await refreshOf(h.license), licensedJson);
      expect(h.http.bodyOf('validate').containsKey('fingerprints'), isFalse);
      expect(h.http.bodyOf('validate').containsKey('fingerprintKind'), isFalse);
    });

    test('does not stand a device refusal given for this device on a run that cannot tell', () async {
      final h = await Harness.create(fingerprinter: ScriptedFingerprinter(const DeviceIdentity(fingerprint: null)));
      holding(h, await machineLease(h), {'refused': 'device', 'refusedFor': [fingerprintClaim('fp-test')]});
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
    });
  });

  group('deviceHold false', () {
    test('holds nothing to its device: no kind sent, no lease judged by its device', () async {
      final h = await Harness.create(fingerprinter: machine('fp-machine'), deviceHold: false);
      h.activates(await machineLease(h, device: 'fp-machine'));
      expect(await h.license.activate(key1), isA<Activated>());
      expect(h.http.bodyOf('activate')['fingerprint'], 'fp-machine');
      expect(h.http.bodyOf('activate').containsKey('fingerprintKind'), isFalse);
      expect(h.stored?.deviceKind, isNull);
      // A machine-keyed lease for another machine: not judged.
      final elsewhere = await machineLease(h, device: 'fp-another-machine');
      holding(h, elsewhere);
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
      // And the server is told no fingerprints to check.
      h.http.fail = false;
      h.renews(elsewhere);
      expect(await refreshOf(h.license), licensedJson);
      expect(h.http.bodyOf('validate').containsKey('fingerprints'), isFalse);
      expect(h.http.bodyOf('validate').containsKey('fingerprintKind'), isFalse);
    });

    test("writes no machine kind, and holds a device refusal to no device after the call it answers", () async {
      final h = await Harness.create(fingerprinter: machine('fp-machine'), deviceHold: false);
      holding(h, await machineLease(h, device: 'fp-machine'));
      refuses(h, 'device');
      expect(await refreshOf(h.license), invalid('device'));
      expect(h.stored?.deviceKind, isNull);
      expect(h.stored?.refused, Refusal.device);
      // Given for no device this run could name, it stands for none after it.
      expect(h.stored?.refusedFor, isEmpty);
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
    });
  });
}
