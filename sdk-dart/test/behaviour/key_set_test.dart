// A key set: leases signed by a staged key, and by a key the build does not
// carry (key-set.test.ts 'a key set'; KeySetTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/harness.dart';
import '../support/status_support.dart';

/// The harness's app, rebuilt with another key set (its storage, clock, device and server kept).
KeyGrantLicense build(Harness h, {List<Map<String, Object?>>? publicJwks, Map<String, Object?>? publicJwk}) =>
    KeyGrantLicense(LicenseConfig(
      product: product,
      apiBaseUrl: 'https://api.test/',
      publicJwks: publicJwks,
      publicJwk: publicJwk,
      adapters: h.config.adapters,
    ));

Matcher configError(String text) =>
    throwsA(isA<LicenseConfigError>().having((e) => e.message, 'message', contains(text)));

void main() {
  test('activates on a lease the staged key signed when the build carries it, and reports the ids it carries', () async {
    final h = await Harness.create();
    final next = await Signer.create();
    final lease = await next.lease(key1);
    h.activates(lease);
    final app = build(h, publicJwks: [h.signer.publicJwk, next.publicJwk]);
    expect(await app.activate(key1), isA<Activated>());
    expect(h.http.bodyOf('activate')['kids'], [h.signer.kid, next.kid]);
    expect(h.stored?.lease, lease);
  });

  test('refuses an activation whose lease names a key the build does not carry, storing nothing', () async {
    final h = await Harness.create();
    final next = await Signer.create();
    h.activates(await next.lease(key1));
    final result = await h.license.activate(key1);
    expect(result, isA<ActivateFailed>().having((r) => r.error, 'error', LicenseError.invalidLease));
    expect(h.stored?.lease, isNull);
  });

  test('answers a stored lease signed by a key the build does not carry as invalid, unknown-key, with the key', () async {
    final h = await Harness.create();
    final next = await Signer.create();
    h.hold(await next.lease(key1));
    h.http.fail = true;
    expect(await statusOf(h.license), invalid('unknown-key'));
    expect(validates(h), 1);
  });

  test('heals a stored lease signed by a key the build does not carry when the server signs with one it does', () async {
    final h = await Harness.create();
    final next = await Signer.create();
    h.hold(await next.lease(key1));
    final fresh = await h.signer.lease(key1);
    h.renews(fresh);
    expect(await statusOf(h.license), licensedJson);
    expect(h.stored?.lease, fresh);
  });

  test('keeps the lease it holds when a renewal brings one signed by a key the build does not carry', () async {
    final h = await Harness.create();
    final next = await Signer.create();
    // A day left of thirty: due to renew early.
    final held = await h.signer.lease(key1, at: now0 - 29 * day);
    h.hold(held);
    h.renews(await next.lease(key1));
    expect(await statusOf(h.license), licensedJson);
    expect(validates(h), 1);
    expect(h.stored?.lease, held);
  });

  test('sends the ids of the keys it carries with each validate', () async {
    final h = await Harness.create();
    h.hold(await h.signer.lease(key1, ttlSeconds: 2 * 86400));
    answers(h, 503);
    await h.license.refresh();
    expect(h.http.bodyOf('validate')['kids'], [h.signer.kid]);
  });

  test('takes publicJwk alone as a set of one: a lease naming its key verifies, and one naming none', () async {
    final h = await Harness.create();
    final app = build(h, publicJwk: h.signer.publicJwk);
    h.hold(await h.signer.lease(key1));
    expect(await statusOf(app), licensedJson);
    h.hold(await unnamedLease(h.signer, key1));
    expect(await statusOf(app), licensedJson);
  });

  test('tries every key it carries for a lease naming none', () async {
    final h = await Harness.create();
    final next = await Signer.create();
    final app = build(h, publicJwks: [h.signer.publicJwk, next.publicJwk]);
    h.hold(await unnamedLease(next, key1));
    expect(await statusOf(app), licensedJson);
  });

  test('carries a key given twice once', () async {
    final h = await Harness.create();
    final app = build(h, publicJwks: [h.signer.publicJwk, {...h.signer.publicJwk}]);
    h.hold(await h.signer.lease(key1, ttlSeconds: 2 * 86400));
    answers(h, 503);
    await app.refresh();
    expect(h.http.bodyOf('validate')['kids'], [h.signer.kid]);
  });

  test('takes a key pasted with base64 padding, as every other SDK does', () async {
    final h = await Harness.create();
    final x = h.signer.publicJwk['x'] as String;
    final app = build(h, publicJwks: [
      {...h.signer.publicJwk, 'x': '$x='},
    ]);
    h.hold(await h.signer.lease(key1));
    expect(await statusOf(app), licensedJson);
  });

  test('refuses, when it is made, a key set holding a key that is not an Ed25519 public JWK', () async {
    final h = await Harness.create();
    expect(
        () => build(h, publicJwks: [
              h.signer.publicJwk,
              {'kty': 'EC', 'crv': 'P-256', 'x': 'AA'},
            ]),
        configError('public key 2'));
    expect(
        () => build(h, publicJwks: [
              {'kty': 'OKP', 'crv': 'Ed25519', 'x': 'AAAA'},
            ]),
        configError('public key 1'));
    expect(() => build(h, publicJwk: {...h.signer.publicJwk, 'd': 'secret'}), configError('private key'));
  });

  test('refuses a configuration with no key, an empty set, or both kinds', () async {
    final h = await Harness.create();
    expect(() => build(h), configError('publicJwks'));
    expect(() => build(h, publicJwks: []), configError('publicJwks'));
    expect(() => build(h, publicJwk: h.signer.publicJwk, publicJwks: [h.signer.publicJwk]), configError('not both'));
  });

  test("reads /pubkey's whole answer with parseJwkSet, and refuses keys that are not a list", () async {
    final h = await Harness.create();
    final x = h.signer.publicJwk['x'];
    final keys = parseJwkSet('{"keys":[{"kty":"OKP","crv":"Ed25519","x":"$x"}]}');
    h.hold(await h.signer.lease(key1));
    expect(await statusOf(build(h, publicJwks: keys)), licensedJson);
    expect(() => parseJwkSet('{"keys":{"kty":"OKP"}}'), throwsA(isA<LicenseConfigError>()));
  });
}
