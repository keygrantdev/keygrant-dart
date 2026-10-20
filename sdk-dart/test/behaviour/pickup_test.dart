// Key pickup (the SDK contract, section 13; pickup.test.ts): what pickUp and
// confirmPickUp send and answer, the keys a confirm answered kept in memory,
// and the key restoreByEmail activates.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/pickup.dart';

import '../support/harness.dart';

const address = 'Mara@Studio.example';
const confirm = 'pickup/confirm';

/// A picked key as a confirm's answer carries it, with what a test leaves out filled in.
Map<String, Object?> picked([Map<String, Object?> over = const {}]) => {
      'key': key1,
      'model': 'perpetual',
      'modelName': 'Single',
      'state': 'active',
      'entitlements': <String, Object?>{},
      'expiresAt': null,
      'versions': {'minMajor': 1, 'maxMajor': 1, 'upgradeUntil': null},
      'deviceLimit': 1,
      'activeDevices': 0,
      'held': false,
      ...over,
    };

void confirms(Harness h, List<Map<String, Object?>> keys) => h.http.on(confirm, (_) => HttpResponse(200, {'keys': keys}));

Matcher sendFailed(PickupError e, [int? retryAfter]) =>
    isA<PickUpSendFailed>().having((r) => r.error, 'error', e).having((r) => r.retryAfter, 'retryAfter', retryAfter);
Matcher keysFailed(PickupError e, [int? retryAfter]) =>
    isA<PickUpKeysFailed>().having((r) => r.error, 'error', e).having((r) => r.retryAfter, 'retryAfter', retryAfter);
Matcher restoreFailed(RestoreError e) => isA<RestoreFailed>().having((r) => r.error, 'error', e);

void main() {
  group('pickUp(email)', () {
    test('asks for a code with the address trimmed, and answers sent', () async {
      final h = await Harness.create();
      h.http.on('pickup', (_) => const HttpResponse(200, {'ok': true}));
      expect(await h.license.pickUp('  Mara@Studio.example\n'), isA<PickUpCodeSent>());
      expect(h.http.bodyOf('pickup'), {'email': address});
    });

    test('refuses a blank address before it asks, and answers each refusal as its error', () async {
      final h = await Harness.create();
      expect(await h.license.pickUp('   '), sendFailed(PickupError.invalidEmail));
      expect(h.http.count('pickup'), 0);
      h.http.on('pickup', (_) => const HttpResponse(403, {'error': 'pickup-disabled'}));
      expect(await h.license.pickUp(address), sendFailed(PickupError.pickupDisabled));
      h.http.on('pickup', (_) => const HttpResponse(429, {'error': 'rate-limited', 'retryAfter': 120}));
      expect(await h.license.pickUp(address), sendFailed(PickupError.tooManyAttempts, 120));
      h.http.fail = true;
      expect(await h.license.pickUp(address), sendFailed(PickupError.network));
    });

    test('writes nothing', () async {
      final h = await Harness.create();
      h.http.on('pickup', (_) => const HttpResponse(200, {'ok': true}));
      await h.license.pickUp(address);
      expect(h.storage.writes, 0);
    });
  });

  group('confirmPickUp(email, code)', () {
    test("sends the address, the code and this device's fingerprints, and answers the keys as read", () async {
      final h = await Harness.create();
      confirms(h, [
        {'key': key1, 'model': 'perpetual', 'modelName': 'Single', 'state': 'active', 'held': true}
      ]);
      final res = await h.license.confirmPickUp(address, ' 123 456 ');
      expect(res, isA<PickUpKeysFound>());
      final keys = (res as PickUpKeysFound).keys;
      expect([keys.single.key, keys.single.modelName, keys.single.held], [key1, 'Single', true]);
      final body = h.http.bodyOf(confirm);
      expect([body['email'], body['code']], [address, '123456']);
      expect(body['fingerprints'], isNotEmpty);
      expect(h.storage.writes, 0);
    });

    test('sends no fingerprints for a product whose devices are not held', () async {
      final h = await Harness.create(deviceHold: false);
      confirms(h, []);
      await h.license.confirmPickUp(address, '123456');
      expect(h.http.bodyOf(confirm).containsKey('fingerprints'), isFalse);
    });

    test('refuses a code that is not six digits before it asks, costing the address no try', () async {
      final h = await Harness.create();
      expect(await h.license.confirmPickUp(address, '12345'), keysFailed(PickupError.wrongCode));
      expect(await h.license.confirmPickUp(address, ''), keysFailed(PickupError.wrongCode));
      expect(await h.license.confirmPickUp('  ', '123456'), keysFailed(PickupError.invalidEmail));
      expect(h.http.count(confirm), 0);
    });

    test("answers the server's words, and a 200 that is no pickup answer as network", () async {
      final h = await Harness.create();
      for (final (word, error) in [
        ('wrong-code', PickupError.wrongCode),
        ('code-expired', PickupError.codeExpired),
        ('pickup-disabled', PickupError.pickupDisabled),
      ]) {
        h.http.on(confirm, (_) => HttpResponse(403, {'error': word}));
        expect(await h.license.confirmPickUp(address, '123456'), keysFailed(error), reason: word);
      }
      h.http.on(confirm, (_) => const HttpResponse(429, {'error': 'too-many-attempts', 'retryAfter': 3000}));
      expect(await h.license.confirmPickUp(address, '123456'), keysFailed(PickupError.tooManyAttempts, 3000));
      h.http.on(confirm, (_) => const HttpResponse(200, {'ok': true}));
      expect(await h.license.confirmPickUp(address, '123456'), keysFailed(PickupError.network));
      h.http.fail = true;
      expect(await h.license.confirmPickUp(address, '123456'), keysFailed(PickupError.network));
    });
  });

  group('restoreByEmail', () {
    test('confirms, then activates the key that fits with the address, and stores the activation, never the code', () async {
      final h = await Harness.create();
      confirms(h, [picked()]);
      h.activates(await h.signer.lease(key1));
      expect(await h.license.restoreByEmail(address, '123456'), isA<Restored>());
      expect(h.http.bodyOf('activate')['key'], key1);
      expect(h.http.bodyOf('activate')['email'], address);
      expect(h.http.bodyOf('activate').containsKey('code'), isFalse);
      expect(jsonEncode(h.storedJson).toLowerCase(), isNot(anyOf(contains('studio'), contains('123456'))));
      expect((await h.license.status()).state, LicenseState.licensed);
    });

    test('activates a code-locked key with the code the pickup handed back', () async {
      final h = await Harness.create();
      confirms(h, [picked({'activationCode': '654321'})]);
      h.activates(await h.signer.lease(key1));
      expect(await h.license.restoreByEmail(address, '123456'), isA<Restored>());
      final body = h.http.bodyOf('activate');
      expect([body['key'], body['email'], body['code']], [key1, address, '654321']);
    });

    test('answers no-key for an address with none, and upgrade for keys of an older major, activating nothing', () async {
      final h = await Harness.create(major: 2);
      confirms(h, []);
      expect(await h.license.restoreByEmail(address, '123456'), restoreFailed(RestoreError.noKey));
      confirms(h, [picked()]);
      expect(await h.license.restoreByEmail(address, '654321'), restoreFailed(RestoreError.upgrade));
      expect(h.http.count('activate'), 0);
    });

    test('keeps the confirmed keys in memory: a restore after a failed activation, or after confirmPickUp, asks once', () async {
      final h = await Harness.create();
      confirms(h, [picked()]);
      h.http.on('activate', (_) => const HttpResponse(503, {'error': 'unavailable'}));
      expect(await h.license.restoreByEmail(address, '123456'), restoreFailed(RestoreError.network));
      h.activates(await h.signer.lease(key1));
      expect(await h.license.restoreByEmail(address, ' 123 456 '), isA<Restored>());
      expect(h.http.count(confirm), 1);
      // Done with once activated: the same pair asks again.
      expect((await h.license.confirmPickUp(address, '123456')).ok, isTrue);
      expect(h.http.count(confirm), 2);
    });

    test('a restore after confirmPickUp with the same address and code asks no more', () async {
      final h = await Harness.create();
      confirms(h, [picked()]);
      h.activates(await h.signer.lease(key1));
      expect((await h.license.confirmPickUp('  $address ', '123456')).ok, isTrue);
      expect(await h.license.restoreByEmail(address, '123 456'), isA<Restored>());
      expect(h.http.count(confirm), 1);
    });

    test('asks again with another code, and once the keys are ten minutes old', () async {
      final h = await Harness.create();
      confirms(h, []);
      await h.license.confirmPickUp(address, '123456');
      await h.license.confirmPickUp(address, '654321');
      expect(h.http.count(confirm), 2);
      await h.license.confirmPickUp(address, '654321');
      expect(h.http.count(confirm), 2);
      h.clock.value = now0 + pickupKeysKeepMs - 1;
      await h.license.confirmPickUp(address, '654321');
      expect(h.http.count(confirm), 2);
      h.clock.value = now0 + pickupKeysKeepMs;
      await h.license.confirmPickUp(address, '654321');
      expect(h.http.count(confirm), 3);
    });

    test('asks again when the device clock is set back before the confirm', () async {
      final h = await Harness.create();
      confirms(h, []);
      await h.license.confirmPickUp(address, '123456');
      h.clock.value = now0 - 1;
      await h.license.confirmPickUp(address, '123456');
      expect(h.http.count(confirm), 2);
    });

    test('keeps the keys by the address as sent: another address asks again', () async {
      final h = await Harness.create();
      confirms(h, []);
      await h.license.confirmPickUp(address, '123456');
      await h.license.confirmPickUp('other@studio.example', '123456');
      expect(h.http.count(confirm), 2);
    });

    test('leaves the licence this device holds as it was when a restore fails', () async {
      final h = await Harness.create();
      h.activates(await h.signer.lease(key1));
      expect((await h.license.activate(key1)).ok, isTrue);
      final before = jsonEncode(h.storedJson);
      confirms(h, [picked({'key': 'SLUICE-OTHR-BBBB-CCCC-DDDD'})]);
      h.http.on('activate', (_) => const HttpResponse(409, {'error': 'limit'}));
      expect(await h.license.restoreByEmail(address, '123456'), restoreFailed(RestoreError.limit));
      h.http.fail = true;
      expect(await h.license.restoreByEmail(address, '654321'), restoreFailed(RestoreError.network));
      expect(jsonEncode(h.storedJson), before);
    });

    test("answers a pickup refusal, and an activation's, as they come", () async {
      final h = await Harness.create();
      h.http.on(confirm, (_) => const HttpResponse(403, {'error': 'code-expired'}));
      expect(await h.license.restoreByEmail(address, '123456'), restoreFailed(RestoreError.codeExpired));
      confirms(h, [picked()]);
      h.http.on('activate', (_) => const HttpResponse(409, {'error': 'limit'}));
      expect(await h.license.restoreByEmail(address, '123456'), restoreFailed(RestoreError.limit));
    });

    test('carries the wait a refusal names', () async {
      final h = await Harness.create();
      h.http.on(confirm, (_) => const HttpResponse(503, {'error': 'unavailable', 'retryAfter': 60}));
      final res = await h.license.restoreByEmail(address, '123456');
      expect(res, restoreFailed(RestoreError.tryAgain));
      expect((res as RestoreFailed).retryAfter, 60);
    });
  });

  group('the pieces', () {
    test('asks for a code with an address alone, and confirms with a code', () {
      expect(pickupAsk(address, null).toJson(), {'send': {'email': address}});
      expect(pickupAsk(address, '123456').toJson(), {'send': {'email': address, 'code': '123456'}});
      expect(pickupAsk('', '123456').toJson(), {'refused': 'invalid-email'});
    });

    test('reads a refusal leniently', () {
      expect(pickupRefusal(null).toJson(), {'error': 'network'});
      expect(pickupRefusal({'error': 'unavailable', 'retryAfter': 60}).toJson(), {'error': 'try-again', 'retryAfter': 60});
      expect(pickupRefusal({'error': 'wrong-code', 'retryAfter': 60}).toJson(), {'error': 'wrong-code'});
      expect(pickupRefusal({'error': 'too-many-attempts', 'retryAfter': 1.5}).toJson(), {'error': 'too-many-attempts'});
    });

    test("reads a confirm's keys leniently, and none from what is no answer", () {
      expect(pickedKeysOf({'keys': 'no'}), isNull);
      expect(pickedKeysOf([]), isNull);
      final read = pickedKeysOf({
        'keys': [
          {'key': ''},
          7,
          {'key': key1, 'held': 'yes', 'activationCode': '12345'}
        ]
      });
      expect(read!.map((k) => k.toJson()), [
        {
          'key': key1, 'model': '', 'modelName': null, 'state': '', 'entitlements': <String, Object?>{}, 'expiresAt': null,
          'versions': null, 'deviceLimit': 0, 'activeDevices': 0, 'held': false,
        }
      ]);
    });

    test("judges a key's versions as the server does", () {
      expect(covers(null, 9, now0), isTrue);
      expect(covers(const PickedVersions(minMajor: 2, maxMajor: 3), 1, now0), isFalse);
      expect(covers(const PickedVersions(minMajor: 2, maxMajor: 3), 4, now0), isFalse);
      expect(covers(const PickedVersions(minMajor: 2, maxMajor: 3, upgradeUntil: now0 + 1), 4, now0), isTrue);
      expect(covers(const PickedVersions(minMajor: 2), 40, now0), isTrue);
    });

    test('chooses the key this device holds, then one with a free seat, then the first', () {
      PickedKey key(Map<String, Object?> over) => PickedKey.fromJson(picked(over))!;
      final full = key({'key': 'A', 'activeDevices': 1});
      final free = key({'key': 'B'});
      final held = key({'key': 'C', 'activeDevices': 1, 'held': true});
      expect(chosenKey([full, free, held], 1, now0).toJson(), {'index': 2});
      expect(chosenKey([full, free], 1, now0).toJson(), {'index': 1});
      expect(chosenKey([full, key({'key': 'D', 'activeDevices': 1})], 1, now0).toJson(), {'index': 0});
      final later = key({'versions': {'minMajor': 3, 'maxMajor': null, 'upgradeUntil': null}});
      expect(chosenKey([later], 1, now0).toJson(), {'refused': 'outdated'});
    });
  });
}
