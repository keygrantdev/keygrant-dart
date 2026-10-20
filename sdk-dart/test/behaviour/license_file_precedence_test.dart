// A licence file beside a key, a trial and a key file (the SDK contract, 10.6;
// license-file-precedence.test.ts, LicenseFilePrecedenceTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/files_support.dart';
import '../support/harness.dart';

/// Lets whatever a call left running in the background finish.
Future<void> settled() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A key held with a second under a day left of its two-day lease (due to renew
/// early), inside an open upgrade window: an unforced status asks about it.
Future<void> keyDue(Harness h, [String? licenseFile]) async {
  final lease = await leaseTo3(h,
      ttlSeconds: 2 * 86400, at: now0 - day - 1000, extra: {'upgradeUntil': now0 ~/ 1000 + 30 * 86400});
  h.stored = stateOf({
    'key': key1, 'activationId': 'act_1', 'lease': lease, 'checkedMajor': 2, 'lastSeen': now0,
    if (licenseFile != null) 'licenseFile': licenseFile,
  });
}

Future<String> trialLease(Harness h, {int at = now0}) =>
    h.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 5 * 86400, at: at);

void main() {
  group('a licence file beside a key', () {
    test('wins over a key this device holds, which keeps working once the file is removed', () async {
      final h = await Harness.create();
      final lease = await leaseTo3(h);
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'lease': lease, 'checkedMajor': 2, 'licenseFile': await offlineFile(h), 'lastSeen': now0});
      final app = fileApp(h);
      expect(await app.status(), fileLicensed);
      await app.removeLicenseFile();
      expect(h.stored?.key, key1);
      expect(h.stored?.lease, lease);
      expect(h.stored?.licenseFile, isNull);
      expect(await app.status(), keyLicensed);
    });

    test('is imported over a held key without touching its seat', () async {
      final h = await Harness.create();
      final lease = await leaseTo3(h);
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'lease': lease, 'checkedMajor': 2, 'lastSeen': now0});
      final app = fileApp(h);
      expect((await app.importLicenseFile(await offlineFile(h))).ok, isTrue);
      expect([h.stored?.key, h.stored?.activationId, h.stored?.lease], [key1, 'act_1', lease]);
      await app.removeLicenseFile();
      expect(await app.status(), keyLicensed);
    });

    test('is kept by an activation, typed or from a key file, and still answers', () async {
      final h = await Harness.create();
      final file = await offlineFile(h);
      h.stored = stateOf({'licenseFile': file});
      h.activates(await leaseTo3(h));
      final app = fileApp(h);
      expect((await app.activate(key1)).ok, isTrue);
      expect([h.stored?.key, h.stored?.licenseFile], [key1, file]);
      final fromFile = await app.importLicenseFile(await keyFile(h));
      expect(fromFile, isA<LicenseFileImported>().having((r) => r.kind, 'kind', LicenseFileKind.key));
      expect([h.stored?.key, h.stored?.licenseFile], [key1, file]);
      expect(await app.status(), fileLicensed);
    });

    test('is left alone by deactivate(), which releases only the key', () async {
      final h = await Harness.create();
      final file = await offlineFile(h);
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'lease': await leaseTo3(h), 'licenseFile': file});
      h.http.on('deactivate', (_) => const HttpResponse(200, {}));
      final app = fileApp(h);
      expect((await app.deactivate()).released, isTrue);
      expect(h.stored?.licenseFile, file);
      expect(h.stored?.key, isNull);
      expect(await app.status(), fileLicensed);
    });

    test('that licenses: the held key is neither renewed nor noted, forced or not, though its lease is due', () async {
      final h = await Harness.create();
      await keyDue(h, await offlineFile(h));
      final app = fileApp(h);
      expect(await app.status(), fileLicensed);
      expect(await app.refresh(), fileLicensed);
      await settled();
      expect(h.http.calls, isEmpty);
      expect(h.stored?.keptMajor, isNull);
    });

    test('that licenses, its control: with no file, the same key is asked about and noted unforced', () async {
      final h = await Harness.create();
      await keyDue(h);
      final answered = fileApp(h).status();
      await h.http.whenCalled('validate');
      await answered;
      expect(h.http.count('validate'), 1);
      expect(h.stored?.keptMajor, 2);
    });

    test("that licenses: answers over the key's stored refusal, asking nothing and writing nothing", () async {
      final h = await Harness.create();
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'refused': 'revoked', 'licenseFile': await offlineFile(h)});
      final writes = h.storage.writes;
      expect(await fileApp(h).refresh(), fileLicensed);
      expect(h.http.calls, isEmpty);
      expect(h.storage.writes, writes);
    });

    test('that does not license: gives way to the key', () async {
      final h = await Harness.create();
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'lease': await leaseTo3(h), 'checkedMajor': 2, 'licenseFile': await offlineFile(h)});
      expect(await fileApp(h, revoked: ['lf_1']).status(), keyLicensed);
    });

    test("that does not license: gives way to the key's stored refusal", () async {
      final h = await Harness.create();
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'refused': 'revoked', 'licenseFile': await offlineFile(h)});
      h.http.fail = true;
      expect(await fileApp(h, revoked: ['lf_1']).status(),
          const LicenseStatus(LicenseState.invalid, reason: LicenseReason.revoked, key: key1));
      expect(h.http.count('validate'), 1);
    });
  });

  group('a licence file beside a trial', () {
    test('that licenses: answers before a running trial, whose launch is then not reported', () async {
      final h = await Harness.create();
      h.stored = stateOf({'trialStart': now0, 'trialEndsAt': now0 + 5 * day, 'trialLease': await trialLease(h), 'licenseFile': await offlineFile(h)});
      final app = fileApp(h);
      final writes = h.storage.writes;
      expect(await app.status(), fileLicensed);
      await app.launchReportSettled();
      expect(h.http.calls, isEmpty);
      expect(h.storage.writes, writes);
    });

    test('that licenses, its control: with no file, the same trial reports its launch', () async {
      final h = await Harness.create();
      h.stored = stateOf({'trialStart': now0, 'trialEndsAt': now0 + 5 * day, 'trialLease': await trialLease(h)});
      final app = fileApp(h);
      expect(await app.status(), const LicenseStatus(LicenseState.trial, trialEndsAt: now0 + 5 * day, trialDaysLeft: 5));
      await app.launchReportSettled();
      expect(h.http.count('trial'), 1);
      expect(h.stored?.trialReportedAt, now0);
    });

    test('that does not license: gives way to a running trial of a build the file does not cover', () async {
      final h = await Harness.create();
      h.stored = stateOf({
        'trialStart': now0, 'trialEndsAt': now0 + 5 * day, 'trialLease': await trialLease(h), 'trialAt': now0,
        'licenseFile': await offlineFile(h, {'major': 1}),
      });
      expect(await fileApp(h).status(), const LicenseStatus(LicenseState.trial, trialEndsAt: now0 + 5 * day, trialDaysLeft: 5));
    });

    test('that does not license: answers in place of an ended trial, since why is the news', () async {
      final h = await Harness.create();
      h.stored = stateOf({
        'trialStart': now0 - 10 * day, 'trialEndsAt': now0 - 5 * day, 'trialLease': await trialLease(h, at: now0 - 10 * day),
        'trialAt': now0, 'licenseFile': await offlineFile(h, {'major': 1}),
      });
      expect(await fileApp(h).status(), fileInvalid(LicenseReason.upgrade));
      expect(h.http.calls, isEmpty);
    });
  });

  group('a key file', () {
    test('activates its key online, as a typed key, and stores the activation, never the file', () async {
      final h = await Harness.create();
      final lease = await leaseTo3(h);
      h.activates(lease);
      final app = fileApp(h);
      final result = await app.importLicenseFile(fileText(await keyFile(h)));
      expect(result, isA<LicenseFileImported>()
          .having((r) => r.kind, 'kind', LicenseFileKind.key)
          .having((r) => r.licensedTo, 'licensedTo', const LicensedTo(email: adaEmail)));
      expect(h.http.bodyOf('activate')['key'], key1);
      expect(h.http.bodyOf('activate')['major'], 2);
      expect([h.stored?.key, h.stored?.activationId, h.stored?.lease], [key1, 'act_1', lease]);
      expect(h.stored?.licenseFile, isNull);
      expect(await app.status(), keyLicensed);
    });

    test("answers with activate()'s error when the server refuses the key, or cannot be asked", () async {
      final h = await Harness.create();
      h.http.on('activate', (_) => const HttpResponse(403, {'error': 'limit'}));
      Matcher failed(LicenseError e) => isA<LicenseFileActivationFailed>().having((r) => r.error, 'error', e);
      expect(await fileApp(h).importLicenseFile(await keyFile(h)), failed(LicenseError.limit));
      h.http.fail = true;
      expect(await fileApp(h).importLicenseFile(await keyFile(h)), failed(LicenseError.network));
    });

    test('throws where activate() does: the state cannot be read', () async {
      final h = await Harness.create();
      final app = fileApp(h);
      final token = await keyFile(h);
      h.storage.failRead(1);
      await expectLater(app.importLicenseFile(token), throwsA(isA<FileSystemLikeError>()));
      expect(h.http.calls, isEmpty);
    });

    test('is refused before any request when it is not for this app, judging no version', () async {
      final h = await Harness.create();
      final app = fileApp(h, revoked: ['lf_2'], major: 9);
      Matcher refused(LicenseFileError e) => isA<LicenseFileRefused>().having((r) => r.error, 'error', e);
      expect(await app.importLicenseFile(await keyFile(h, {'product': 'maindeck'})), refused(LicenseFileError.wrongProduct));
      expect(await app.importLicenseFile(await keyFile(h)), refused(LicenseFileError.revokedFile));
      expect(h.http.calls, isEmpty);
    });
  });
}
