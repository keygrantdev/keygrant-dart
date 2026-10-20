// A key for a range of versions, a 0.x build, and upgradeUrl()
// (license.test.ts 'a key for a range of versions', 'upgradeUrl';
// major.test.ts; StatusTests.swift, MajorTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/lease.dart' show openMajor;

import '../support/harness.dart';
import '../support/status_support.dart';

/// A lease covering `minMajor` (absent: 1) to `major`.
Future<String> rangeLease(Harness h, int major, [int? minMajor]) =>
    h.signer.lease(key1, major: major, extra: {if (minMajor != null) 'minMajor': minMajor});

void storeLease(Harness h, String lease) =>
    store(h, {'key': key1, 'activationId': 'act_1', 'lease': lease, 'lastSeen': now0});

void main() {
  group('a key for a range of versions', () {
    test('reports outdated offline for a build older than the key covers', () async {
      final h = await Harness.create(major: 1);
      storeLease(h, await rangeLease(h, 3, 2));
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('outdated'));
    });

    test('licenses every build inside the range, its lowest and highest included', () async {
      for (final major in [2, 3]) {
        final h = await Harness.create(major: major);
        storeLease(h, await rangeLease(h, 3, 2));
        expect((await h.license.status()).state, LicenseState.licensed, reason: 'major $major');
      }
    });

    test('reports upgrade for a build above the range', () async {
      final h = await Harness.create(major: 4);
      storeLease(h, await rangeLease(h, 3, 2));
      h.http.fail = true;
      expect(await statusOf(h.license), invalid('upgrade'));
    });

    test('reads a lease with no lowest major as starting at 1', () async {
      final h = await Harness.create(major: 1);
      storeLease(h, await rangeLease(h, 1));
      expect((await h.license.status()).state, LicenseState.licensed);
    });

    test('runs any later build on an open-ended key', () async {
      final h = await Harness.create(major: 41);
      storeLease(h, await rangeLease(h, openMajor, 2));
      expect((await h.license.status()).state, LicenseState.licensed);
    });

    test("maps the server's update-required to outdated on activate", () async {
      final h = await Harness.create();
      h.http.on('activate', (_) => const HttpResponse(403, {'error': 'update-required'}));
      final result = await h.license.activate(key1);
      expect(result, isA<ActivateFailed>().having((r) => r.error, 'error', LicenseError.outdated));
    });

    test('reports outdated when renewal says update-required', () async {
      final h = await Harness.create();
      storeLease(h, await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day));
      refuses(h, 'update-required');
      expect(await statusOf(h.license), invalid('outdated'));
    });

    test('keeps a renewed lease that starts above this build, and reports outdated', () async {
      final h = await Harness.create(major: 1);
      storeLease(h, await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day));
      final fresh = await rangeLease(h, 2, 2);
      answers(h, 200, {'lease': fresh, 'activationId': 'act_1'});
      expect(await statusOf(h.license), invalid('outdated'));
      expect(h.stored?.lease, fresh);
    });
  });

  group('a 0.x build (major 0)', () {
    test('is licensed offline by a lease for major 1, not refused as outdated', () async {
      final h = await Harness.create(major: 0);
      holding(h, await rangeLease(h, 1));
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
    });

    test('sends major 1 with its activation and its validate, as the server reads it', () async {
      final h = await Harness.create(major: 0);
      final lease = await rangeLease(h, 1);
      h.activates(lease);
      h.renews(lease);
      expect(await h.license.activate(key1), isA<Activated>());
      expect(await refreshOf(h.license), licensedJson);
      expect(h.http.bodyOf('activate')['major'], 1);
      expect(h.http.bodyOf('validate')['major'], 1);
      expect(h.stored?.checkedMajor, 1);
    });

    test('reads a negative major as 1 too', () async {
      final h = await Harness.create(major: -3);
      holding(h, await rangeLease(h, 1));
      h.http.fail = true;
      expect(await statusOf(h.license), licensedJson);
      expect(h.http.calls, isEmpty);
    });
  });

  group('upgradeUrl', () {
    Future<Harness> activation([String activationId = 'act_1']) =>
        Harness.create().then((h) => h..hold('L', {'activationId': activationId}));

    test("names this device's activation on a payment link, for an upgrade sale to find", () async {
      final h = await activation('act_device1');
      expect(await h.license.upgradeUrl('https://buy.stripe.com/test_abc'),
          'https://buy.stripe.com/test_abc?client_reference_id=act_device1');
    });

    test('never puts the licence key in the URL', () async {
      final h = await activation('act_device1');
      final url = await h.license.upgradeUrl('https://buy.stripe.com/test_abc?client_reference_id=x');
      expect(url, isNot(contains('SLUICE')));
    });

    test("keeps the link's own parameters, and replaces a client_reference_id already on it", () async {
      final h = await activation();
      final url = await h.license.upgradeUrl('https://buy.stripe.com/x?prefilled_email=jo%40example.com&client_reference_id=old');
      final params = Uri.parse(url!).queryParametersAll;
      expect(params['prefilled_email'], ['jo@example.com']);
      expect(params['client_reference_id'], ['act_1']);
    });

    for (final (link, expected) in [
      ('https://buy.test/u', 'https://buy.test/u?client_reference_id=act_1'),
      ('https://buy.test/u#pay', 'https://buy.test/u?client_reference_id=act_1#pay'),
      ('https://buy.test/u?client_reference_id=old&a=1', 'https://buy.test/u?a=1&client_reference_id=act_1'),
    ]) {
      test('sets the reference on $link', () async {
        final h = await activation();
        expect(await h.license.upgradeUrl(link), expected);
      });
    }

    test('encodes an activation id that is not plain text', () async {
      final h = await activation('act 1&x=é');
      expect(await h.license.upgradeUrl('https://buy.test/u'), 'https://buy.test/u?client_reference_id=act%201%26x%3D%C3%A9');
    });

    test('throws an ArgumentError for a link that is not an absolute URL', () async {
      final h = await activation();
      for (final link in ['/buy', 'buy.stripe.com/test_abc']) {
        await expectLater(h.license.upgradeUrl(link), throwsArgumentError, reason: link);
      }
    });

    test('is null on a device holding no activated licence, asking nothing', () async {
      for (final state in [
        {'trialStart': now0},
        {'key': 'KEY-1'},
        {'key': '', 'activationId': 'act_1'},
        <String, Object?>{},
      ]) {
        final h = await Harness.create();
        store(h, state);
        expect(await h.license.upgradeUrl('https://buy.stripe.com/test_abc'), isNull, reason: '$state');
        expect(h.http.calls, isEmpty);
      }
    });

    test('writes nothing, and throws the storage error, when the state cannot be read', () async {
      final h = await activation();
      h.storage.failRead(1);
      await expectLater(h.license.upgradeUrl('https://buy.test/u'), throwsA(isA<FileSystemLikeError>()));
      expect(h.storage.writes, 0);
    });
  });
}
