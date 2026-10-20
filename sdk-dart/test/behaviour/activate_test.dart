// activate() (the SDK contract, 5.4; license.test.ts `activate`).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/harness.dart';

void main() {
  test('stores a verified lease and reports licensed', () async {
    final h = await Harness.create();
    h.activates(await h.signer.lease(key1));
    expect((await h.license.activate(key1)).ok, isTrue);
    expect(h.storedJson['key'], key1);
    expect(h.storedJson['activationId'], 'act_1');
    final status = await h.license.status();
    expect(status.state, LicenseState.licensed);
    expect(status.key, key1);
    expect(h.http.count('validate'), 0);
  });

  test('normalises a pasted key: trimmed and upper-cased before it is sent and stored', () async {
    final h = await Harness.create();
    h.activates(await h.signer.lease(key1));
    expect((await h.license.activate('  ${key1.toLowerCase()}\n')).ok, isTrue);
    expect(h.http.bodyOf('activate')['key'], key1);
    expect(h.storedJson['key'], key1);
  });

  test('refuses an empty key, and one longer than any, asking nothing', () async {
    final h = await Harness.create();
    for (final key in ['', '   ', 'K' * 121]) {
      final result = await h.license.activate(key);
      expect(result, isA<ActivateFailed>().having((r) => r.error, 'error', LicenseError.invalidKey));
    }
    expect(h.http.calls, isEmpty);
  });

  test('sends a key of exactly the limit', () async {
    final h = await Harness.create();
    await h.license.activate('K' * 120);
    expect(h.http.bodyOf('activate')['key'], 'K' * 120);
  });

  test('cuts a device name the server would refuse, never a character in half', () async {
    final h = await Harness.create(deviceName: '${'x' * 119}\u{1F600}');
    await h.license.activate(key1);
    expect(h.http.bodyOf('activate')['name'], 'x' * 119);
  });

  test('sends the body the contract names, absent members left out', () async {
    final h = await Harness.create(major: 3);
    await h.license.activate(key1);
    final body = h.http.bodyOf('activate');
    expect(body.keys.toSet(), {'key', 'fingerprint', 'major', 'kids'});
    expect(body['fingerprint'], 'fp-test');
    expect(body['major'], 3);
    expect(body['kids'], [h.signer.kid]);
  });

  test('answers network on a transport failure, and on a 200 without a lease or activation', () async {
    final h = await Harness.create();
    h.http.fail = true;
    expect((await h.license.activate(key1) as ActivateFailed).error, LicenseError.network);
    h.http.fail = false;
    h.http.on('activate', (_) => const HttpResponse(200, {'lease': 'x'}));
    expect((await h.license.activate(key1) as ActivateFailed).error, LicenseError.network);
    h.http.on('activate', (_) => const HttpResponse(200, {'activationId': 'act_1'}));
    expect((await h.license.activate(key1) as ActivateFailed).error, LicenseError.network);
    expect(h.stored, isNull);
  });

  test('answers invalid-lease when the lease does not verify here', () async {
    final h = await Harness.create();
    final other = await Signer.create();
    h.activates(await other.lease(key1));
    expect((await h.license.activate(key1) as ActivateFailed).error, LicenseError.invalidLease);
    expect(h.stored, isNull);
  });

  test("maps the server's words to the app's errors", () async {
    final h = await Harness.create();
    final words = {
      'invalid-key': LicenseError.invalidKey,
      'limit': LicenseError.limit,
      'revoked': LicenseError.revoked,
      'expired': LicenseError.revoked,
      'upgrade-required': LicenseError.upgrade,
      'update-required': LicenseError.outdated,
      'user-email-required': LicenseError.userEmailRequired,
      'try-again': LicenseError.tryAgain,
      'something-new': LicenseError.network,
    };
    for (final MapEntry(key: word, value: error) in words.entries) {
      h.http.on('activate', (_) => HttpResponse(403, {'error': word}));
      expect((await h.license.activate(key1) as ActivateFailed).error, error, reason: word);
    }
  });

  test('throws when the activation cannot be saved: the app offers to try again', () async {
    final h = await Harness.create();
    h.activates(await h.signer.lease(key1));
    h.storage.failWrites = true;
    expect(h.license.activate(key1), throwsA(isA<FileSystemLikeError>()));
  });
}
