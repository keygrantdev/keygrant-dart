// A save that fails once the server has answered (license.test.ts): the
// server's answer stands, a trial is kept in memory and saved by the next call
// that can, and the calls the customer asked for fail with the key kept.

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/harness.dart';
import '../support/trials_support.dart';

/// startTrial() asked at now0, its answer (ending now0 + 5 days) kept unsaved.
Future<Harness> keptTrial() async {
  final h = await Harness.create();
  answersTrial(h, start: now0 - 2 * day, ends: now0 + 5 * day, lease: await trialLeaseOf(h.signer));
  h.storage.failWrites = true;
  expect((await h.license.startTrial()).trialDaysLeft, 5);
  return h;
}

/// [keptTrial], then another instance saves `theirs`, and writes work again unless `stillFailing`.
Future<Harness> keptThen(Future<Map<String, Object?>> Function(Harness h) theirs, {bool stillFailing = false}) async {
  final h = await keptTrial();
  storeJson(h, await theirs(h));
  h.storage.failWrites = stillFailing;
  return h;
}

void main() {
  test("is the server's refusal all the same, the stored lease untouched", () async {
    final h = await Harness.create();
    final lease = await h.signer.lease(key1);
    h.hold(lease, {'checkedMajor': 1, 'lastSeen': now0});
    h.http.on('validate', (_) => const HttpResponse(403, {'error': 'revoked'}));
    h.storage.failWrites = true;
    expect(await h.license.refresh(), const LicenseStatus(LicenseState.invalid, reason: LicenseReason.revoked, key: key1));
    expect(h.storage.writes, greaterThan(0));
    expect(h.stored!.lease, lease);
  });

  test("is the server's renewal all the same, for a lease that had run out, written by the next call that can", () async {
    final h = await Harness.create();
    final old = await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day);
    h.hold(old, {'checkedMajor': 1, 'lastSeen': now0});
    final fresh = await h.signer.lease(key1);
    h.renews(fresh);
    h.storage.failWrites = true;
    expect(await h.license.status(), licensedStatus());
    expect(h.stored!.lease, old);
    h.storage.failWrites = false;
    expect(await h.license.refresh(), licensedStatus());
    expect(h.stored!.lease, fresh);
  });

  test('is no answer at all, rather than a rejection, when nothing answered either', () async {
    final h = await Harness.create();
    h.hold(await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day), {'checkedMajor': 1, 'lastSeen': now0});
    h.http.fail = true;
    h.storage.failWrites = true;
    expect(await h.license.status(), const LicenseStatus(LicenseState.expired, reason: LicenseReason.offline, key: key1));
  });

  test("is the server's trial all the same, from startTrial()", () async {
    final h = await keptTrial();
    expect(h.stored, isNull);
  });

  test('still fails deactivate(), which the customer asked for, the key kept to try again', () async {
    final h = await Harness.create();
    final lease = await h.signer.lease(key1);
    h.hold(lease, {'checkedMajor': 1, 'lastSeen': now0});
    h.http.on('deactivate', (_) => const HttpResponse(200, {'ok': true}));
    h.storage.failWrites = true;
    await expectLater(h.license.deactivate(), throwsA(isA<FileSystemLikeError>()));
    expect(h.stored!.key, key1);
    expect(h.stored!.lease, lease);
  });

  test('still fails activate(), which the customer asked for and can try again', () async {
    final h = await Harness.create();
    h.activates(await h.signer.lease(key1));
    h.storage.failWrites = true;
    await expectLater(h.license.activate(key1), throwsA(isA<FileSystemLikeError>()));
  });

  test('keeps a trial it could not save for the process, answers it, and saves it once it can', () async {
    final h = await keptTrial();
    // The next status() reads no trial on the disk, and answers the one it holds.
    expect((await h.license.status()).trialDaysLeft, 5);
    expect(h.stored, isNull);
    h.storage.failWrites = false;
    expect((await h.license.status()).trialDaysLeft, 5);
    expect(h.storedJson['trialStart'], now0 - 2 * day);
    expect(h.storedJson['trialEndsAt'], now0 + 5 * day);
    expect(h.storedJson['trialLease'], isNotNull);
    // Saved once: not written again by every status() after it.
    await h.license.launchReportSettled();
    final writes = h.storage.writes;
    await h.license.status();
    expect(h.storage.writes, writes);
  });

  test('never moves a trial start later when it saves the trial it kept', () async {
    final h = await keptThen((_) async => {'trialStart': now0 - 9 * day});
    await h.license.status();
    expect(h.storedJson['trialStart'], now0 - 9 * day);
    expect(h.storedJson['trialEndsAt'], now0 + 5 * day);
  });

  group('a kept trial, and a newer trial answer another instance saved', () {
    test("never makes the trial longer: the newer answer's earlier end stands", () async {
      final h = await keptThen((_) async => {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 - 2 * day, 'trialAt': now0 + 1});
      expect(await h.license.status(), trialOver);
      expect(h.storedJson['trialStart'], now0 - 9 * day);
      expect(h.storedJson['trialEndsAt'], now0 - 2 * day);
      expect(h.storedJson['trialAt'], now0 + 1);
    });

    test("answers the newer answer's end while its own still cannot be saved", () async {
      final h = await keptThen((_) async => {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 - 2 * day, 'trialAt': now0 + 1},
          stillFailing: true);
      expect(await h.license.status(), trialOver);
    });

    test("takes the newer answer's later end too: a trial the server extended", () async {
      final h = await keptThen((x) async => {
            'trialStart': now0 - 9 * day,
            'trialEndsAt': now0 + 20 * day,
            'trialLease': await trialLeaseOf(x.signer, days: 20),
            'trialAt': now0 + 1,
          });
      expect((await h.license.status()).trialDaysLeft, 20);
      expect(h.storedJson['trialEndsAt'], now0 + 20 * day);
    });

    test('wins over a stored trial with no stamp', () async {
      final h = await keptThen((_) async => {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 - 2 * day});
      expect((await h.license.status()).trialDaysLeft, 5);
      expect(h.storedJson['trialStart'], now0 - 9 * day);
      expect(h.storedJson['trialEndsAt'], now0 + 5 * day);
      expect(h.storedJson['trialAt'], now0);
    });

    test('saves its trial after a deactivate, the licence as that left it', () async {
      final h = await keptThen((_) async => {'trialStart': now0 - 9 * day});
      await h.license.status();
      expect(h.storedJson['trialStart'], now0 - 9 * day);
      expect(h.storedJson['trialEndsAt'], now0 + 5 * day);
      expect(h.storedJson['trialAt'], now0);
      expect(h.stored!.key, isNull);
    });

    test("saves its trial after another key's activation, the licence as that left it", () async {
      const other = 'SLUICE-BBBB-BBBB-BBBB-BBBB';
      final h = await keptThen((_) async => {'key': other, 'activationId': 'act_2', 'lease': 'LB', 'checkedMajor': 1});
      await h.license.status();
      expect(h.storedJson['key'], other);
      expect(h.storedJson['activationId'], 'act_2');
      expect(h.storedJson['lease'], 'LB');
      expect(h.storedJson['trialStart'], now0 - 2 * day);
      expect(h.storedJson['trialEndsAt'], now0 + 5 * day);
      expect(h.storedJson['trialAt'], now0);
    });
  });
}
