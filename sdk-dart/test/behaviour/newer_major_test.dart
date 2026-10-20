// The check of a newer major: once, bounded, and backing off (license.test.ts
// 'the check of a newer major: once, bounded, and backing off';
// RefusalTests.swift).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/lease.dart' show openMajor;
import 'package:keygrant/src/core/offline.dart' show askAgainMs, retryUnansweredMs;

import '../support/harness.dart';
import '../support/status_support.dart';

Future<String> openLease(Harness h, {String model = 'perpetual', int ttlSeconds = 30 * 86400, String aid = 'act_1'}) =>
    h.signer.lease(key1, model: model, ttlSeconds: ttlSeconds, aid: aid, major: openMajor);

/// A device on 3 holding a valid open lease, last heard by the server on 2.
Future<Harness> onNewMajor({Timing timing = Timing.standard}) async {
  final h = await Harness.create(major: 3, timing: timing);
  holding(h, await openLease(h), {'checkedMajor': 2});
  return h;
}

void main() {
  for (final (error, reason) in [
    ('revoked', 'revoked'),
    ('expired', 'revoked'),
    ('deactivated', 'revoked'),
    ('upgrade-required', 'upgrade'),
    ('update-required', 'outdated'),
  ]) {
    test('records the major as heard on a $error refusal, keeps the refusal, and does not ask again', () async {
      final h = await onNewMajor();
      refuses(h, error);
      expect(await statusOf(h.license), invalid(reason));
      expect(h.stored?.checkedMajor, 3);
      expect(h.stored?.refused?.wire, reason);
      expect(h.stored?.activationId, 'act_1');
      expect(await statusOf(h.license), invalid(reason));
      expect(validates(h), 1);
    });
  }

  for (final error in ['revoked', 'expired', 'deactivated']) {
    test('drops the lease on a $error verdict, which is about the key', () async {
      final h = await onNewMajor();
      refuses(h, error);
      await h.license.status();
      expect(h.stored?.lease, isNull);
      expect(h.stored?.refusedMajor, isNull);
    });
  }

  for (final (error, reason) in [('upgrade-required', Refusal.upgrade), ('update-required', Refusal.outdated)]) {
    test('keeps the lease on a $error verdict, which is about this build, with the major refused', () async {
      final h = await onNewMajor();
      refuses(h, error);
      await h.license.status();
      expect(h.stored?.refused, reason);
      expect(h.stored?.refusedMajor, 3);
      expect(h.stored?.lease, isNotNull);
    });
  }

  test('lets a rollback to a covered build run offline after its newer build was refused an upgrade', () async {
    final h = await onNewMajor();
    refuses(h, 'upgrade-required');
    expect(await statusOf(h.licenseFor(4)), invalid('upgrade'));
    h.http.fail = true;
    expect((await h.licenseFor(3).status()).state, LicenseState.licensed);
    expect(await statusOf(h.licenseFor(4)), invalid('upgrade'));
    expect(await statusOf(h.licenseFor(5)), invalid('upgrade'));
    expect(validates(h), 1);
  });

  test('lets an update to a covered build run offline after its older build was refused as out of date', () async {
    final h = await onNewMajor();
    refuses(h, 'update-required');
    expect(await statusOf(h.license), invalid('outdated'));
    h.http.fail = true;
    expect(await statusOf(h.licenseFor(3)), invalid('outdated'));
    expect((await h.licenseFor(4).status()).state, LicenseState.licensed);
    expect(await statusOf(h.licenseFor(2)), invalid('outdated'));
  });

  test('keeps a cancelled subscriber on a new major refused on this status() and the next, offline included', () async {
    final h = await Harness.create(major: 3);
    holding(h, await openLease(h, model: 'subscription', ttlSeconds: 7 * 86400), {'checkedMajor': 2});
    refuses(h, 'expired');
    expect(await statusOf(h.license), invalid('revoked'));
    expect(await statusOf(h.license), invalid('revoked'));
    h.http.fail = true;
    expect(await statusOf(h.license), invalid('revoked'));
    expect(await refreshOf(h.license), invalid('revoked'));
  });

  test('heals a refused key when the server licenses it again, and forgets the refusal', () async {
    final h = await onNewMajor();
    refuses(h, 'expired');
    expect((await h.license.status()).state, LicenseState.invalid);
    h.clock.value = now0 + askAgainMs;
    h.renews(await openLease(h));
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(h.stored?.refused, isNull);
    h.http.fail = true;
    expect((await h.license.status()).state, LicenseState.licensed);
  });

  test('keeps a lease an ambiguous answer comes back on, and records no refusal', () async {
    final h = await onNewMajor();
    answers(h, 404, {'error': 'unknown-product'});
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(h.stored?.refused, isNull);
    expect(h.stored?.lease, isNotNull);
  });

  test('starts afresh on a new activation after a refusal, and on a deactivate', () async {
    final h = await onNewMajor();
    refuses(h, 'deactivated');
    expect((await h.license.status()).state, LicenseState.invalid);
    h.activates(await openLease(h, aid: 'act_2'), activationId: 'act_2');
    expect(await h.license.activate(key1), isA<Activated>());
    expect(h.stored?.refused, isNull);
    h.http.fail = true;
    expect((await h.license.status()).state, LicenseState.licensed);

    store(h, {...h.storedJson, 'refused': 'revoked'});
    await h.license.deactivate();
    expect(h.stored?.refused, isNull);
    expect(await statusOf(h.license), {'state': 'unlicensed'});
  });

  test('asks a refused key again only once the wait is over, and at once on a refresh()', () async {
    final h = await onNewMajor();
    refuses(h, 'revoked');
    expect((await h.license.status()).state, LicenseState.invalid);
    expect(validates(h), 1);
    h.clock.value = now0 + askAgainMs - 1;
    expect(await statusOf(h.license), invalid('revoked'));
    expect(validates(h), 1);
    expect((await h.license.refresh()).state, LicenseState.invalid);
    expect(validates(h), 2);
    // The refresh's refusal starts the wait afresh.
    h.clock.value = now0 + 2 * askAgainMs - 2;
    await h.license.status();
    expect(validates(h), 2);
    h.clock.value = now0 + 2 * askAgainMs - 1;
    await h.license.status();
    expect(validates(h), 3);
  });

  test('asks for an expired lease again only once the wait is over, and at once on a refresh()', () async {
    final h = await Harness.create();
    store(h, {'key': key1, 'activationId': 'act_1', 'lease': await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day), 'lastSeen': now0});
    h.http.fail = true;
    expect(await statusOf(h.license), expiredOffline);
    expect(h.stored?.backoffSince, now0);
    expect(h.stored?.backoffMs, retryUnansweredMs);
    h.clock.value = now0 + retryUnansweredMs - 1;
    expect((await h.license.status()).state, LicenseState.expired);
    expect(validates(h), 1);
    h.clock.value = now0 + retryUnansweredMs;
    await h.license.status();
    expect(validates(h), 2);
    await h.license.refresh();
    expect(validates(h), 3);
    h.http.fail = false;
    h.renews(await h.signer.lease(key1, at: now0 + retryUnansweredMs));
    expect((await h.license.refresh()).state, LicenseState.licensed);
    expect(h.stored?.backoffSince, isNull);
  });

  test('serialises overlapping status() calls: one question, and the refusal survives', () async {
    final h = await onNewMajor();
    final answer = Completer<HttpResponse>();
    var asked = 0;
    h.http.on('validate', (_) {
      asked++;
      return asked > 1 ? const HttpResponse(503, {'error': 'busy'}) : answer.future;
    });
    final first = h.license.status();
    final second = h.license.status();
    await h.http.whenCalled('validate');
    answer.complete(const HttpResponse(403, {'error': 'revoked'}));
    expect(js(await first), invalid('revoked'));
    expect(js(await second), invalid('revoked'));
    expect(asked, 1);
    expect(h.stored?.refused, Refusal.revoked);
    expect(h.stored?.checkedMajor, 3);
    expect(h.stored?.lease, isNull);
  });

  test('records the major as heard on an answer it cannot use, and does not ask again', () async {
    final h = await onNewMajor();
    answers(h, 200, {'lease': 'not.a.lease'});
    expect((await h.license.status()).state, LicenseState.licensed);
    await h.license.status();
    expect(validates(h), 1);
    expect(h.stored?.checkedMajor, 3);
  });

  test('backs off after no answer, and asks again once the interval has passed', () async {
    final h = await onNewMajor();
    h.http.fail = true;
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(h.stored?.checkedMajor, 2);
    expect(h.stored?.backoffSince, now0);
    expect(h.stored?.backoffMs, retryUnansweredMs);
    h.clock.value = now0 + retryUnansweredMs - 1;
    await h.license.status();
    expect(validates(h), 1);
    h.clock.value = now0 + retryUnansweredMs;
    await h.license.status();
    expect(validates(h), 2);
  });

  for (final status in [503, 429]) {
    test('treats a $status as no verdict, keeps the lease, and waits the hour: the server did answer', () async {
      final h = await onNewMajor();
      answers(h, status, {'error': 'busy'});
      expect((await h.license.status()).state, LicenseState.licensed);
      expect(h.stored?.checkedMajor, 2);
      expect(h.stored?.backoffSince, now0);
      expect(h.stored?.backoffMs, askAgainMs);
      h.clock.value = now0 + retryUnansweredMs;
      await h.license.status();
      expect(validates(h), 1);
      h.clock.value = now0 + askAgainMs;
      await h.license.status();
      expect(validates(h), 2);
    });
  }

  test('bounds the check on a valid lease by the status check bound, given to the adapter too', () async {
    final h = await onNewMajor();
    h.http.fail = true;
    await h.license.status();
    expect(h.http.calls.single.timeout, const Duration(milliseconds: 5000));
  });

  test("returns the valid lease when the network never answers, after at most the check's bound", () async {
    const bound = Duration(milliseconds: 400);
    final h = await onNewMajor(timing: const Timing(statusCheck: bound));
    h.http.hang = true;
    var settled = false;
    final pending = h.license.status().then((s) {
      settled = true;
      return s;
    });
    await h.http.whenCalled('validate');
    final asked = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(settled, isFalse);
    expect(js(await pending), licensedJson);
    expect(DateTime.now().difference(asked), lessThan(const Duration(seconds: 3)));
    expect(h.stored?.backoffSince, now0);
    expect(h.stored?.backoffMs, retryUnansweredMs);
  });
}
