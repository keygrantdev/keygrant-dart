// Licence files (the SDK contract, section 10; license-file.test.ts,
// LicenseFileTests.swift, LicenseFileTypesTests.swift): an offline file taken,
// stored and answered with no network; each refusal; and a stored file that
// does not license this build.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/license_file.dart' show licenseFileToken;

import '../support/files_support.dart';
import '../support/harness.dart';

Matcher imported(LicenseFileKind kind, LicensedTo to) => isA<LicenseFileImported>()
    .having((r) => r.kind, 'kind', kind)
    .having((r) => r.licensedTo, 'licensedTo', to);

Matcher refused(LicenseFileError error) => isA<LicenseFileRefused>().having((r) => r.error, 'error', error);

void main() {
  group('an offline licence file', () {
    test('is taken from its text with no network, stored, and licenses the app as the file', () async {
      final h = await Harness.create();
      final token = await offlineFile(h);
      final app = fileApp(h);
      expect(await app.importLicenseFile(fileText(token)), imported(LicenseFileKind.offline, ada));
      expect(h.stored?.licenseFile, token);
      expect(await app.status(), fileLicensed);
      expect(h.http.calls, isEmpty);
    });

    test('is taken as bytes too: a list of bytes and a Uint8List', () async {
      final h = await Harness.create();
      final token = await offlineFile(h);
      final bytes = utf8.encode(fileText(token));
      for (final content in <List<int>>[bytes, Uint8List.fromList(bytes), List<int>.of(bytes)]) {
        h.stored = null;
        expect(await fileApp(h).importLicenseFileBytes(content), imported(LicenseFileKind.offline, ada));
        expect(h.stored?.licenseFile, token);
      }
    });

    test('never goes online, refresh() included, and writes nothing, though the key beside it has run out', () async {
      final h = await Harness.create();
      final expired = await leaseTo3(h, ttlSeconds: 3600, at: now0 - 2 * day);
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'lease': expired, 'lastSeen': now0, 'licenseFile': await offlineFile(h)});
      final app = fileApp(h);
      final writes = h.storage.writes;
      expect(await app.status(), fileLicensed);
      expect(await app.refresh(), fileLicensed);
      expect(h.http.calls, isEmpty);
      expect(h.storage.writes, writes);
    });

    test('its control: with no file, the same run-out key is asked about and the answer saved', () async {
      final h = await Harness.create();
      final expired = await leaseTo3(h, ttlSeconds: 3600, at: now0 - 2 * day);
      h.stored = stateOf({'key': key1, 'activationId': 'act_1', 'lease': expired, 'lastSeen': now0});
      final writes = h.storage.writes;
      await fileApp(h).status();
      expect(h.http.count('validate'), 1);
      expect(h.storage.writes, greaterThan(writes));
    });

    test('says when it is a test licence, and carries its entitlements, which has() and require() read', () async {
      final h = await Harness.create();
      h.stored = stateOf({
        'licenseFile': await offlineFile(h, {
          'test': true,
          'ent': {'edition': 'pro', 'cloud': true}
        })
      });
      final app = fileApp(h);
      final status = await app.status();
      expect(status.test, isTrue);
      expect(status.entitlements, {'edition': const TextEntitlement('pro'), 'cloud': const FlagEntitlement(true)});
      expect(status.source, LicenseSource.file);
      expect(await app.has('cloud'), isTrue);
      expect(app.require('export'), throwsA(isA<MissingEntitlement>()));
    });

    test('removing none is no error, and leaves unlicensed as it was', () async {
      final h = await Harness.create();
      final app = fileApp(h);
      await app.removeLicenseFile();
      expect(await app.status(), const LicenseStatus(LicenseState.unlicensed));
    });

    test('replaces the file stored before, and a file refused leaves the stored one as it was', () async {
      final h = await Harness.create();
      final first = await offlineFile(h);
      final second = await offlineFile(h, {'fid': 'lf_3', 'name': 'Grace Hopper', 'email': null});
      final app = fileApp(h);
      await app.importLicenseFile(first);
      expect(await app.importLicenseFile(second), imported(LicenseFileKind.offline, const LicensedTo(name: 'Grace Hopper')));
      expect(h.stored?.licenseFile, second);
      expect(await app.importLicenseFile(await offlineFile(h, {'product': 'maindeck'})), refused(LicenseFileError.wrongProduct));
      expect(h.stored?.licenseFile, second);
    });
  });

  group('a licence file refused', () {
    test('names each reason, and stores nothing', () async {
      final h = await Harness.create();
      final other = await Signer.create();
      final token = await offlineFile(h);
      final byOther = await other.file({
        'kind': 'offline', 'fid': 'lf_1', 'sub': key1, 'product': product, 'email': adaEmail, 'major': 3, 'iat': now0 ~/ 1000,
      });
      final app = fileApp(h, revoked: ['lf_9']);
      final cases = <(Object, LicenseFileError)>[
        ('', LicenseFileError.malformed),
        ('$token\n$token', LicenseFileError.malformed),
        (<int>[0xff, 0xfe, 0x00], LicenseFileError.malformed),
        (await leaseTo3(h), LicenseFileError.notALicenseFile),
        (payloadSwapped(token, await offlineFile(h, {'major': 9})), LicenseFileError.badSignature),
        (byOther, LicenseFileError.unknownKey),
        (await offlineFile(h, {'product': 'maindeck'}), LicenseFileError.wrongProduct),
        (await offlineFile(h, {'fid': 'lf_9'}), LicenseFileError.revokedFile),
        (await offlineFile(h, {'major': 1}), LicenseFileError.upgrade),
        (await offlineFile(h, {'minMajor': 3}), LicenseFileError.outdated),
      ];
      for (final (content, error) in cases) {
        final result = content is String ? await app.importLicenseFile(content) : await app.importLicenseFileBytes(content as List<int>);
        expect(result, refused(error), reason: error.wire);
      }
      expect(h.stored?.licenseFile, isNull);
      expect(h.http.calls, isEmpty);
    });

    test('refuses a file larger than the most a file may be, as text or as bytes', () async {
      final h = await Harness.create();
      final padded = '${'#' * maxLicenseFileBytes}\n${await offlineFile(h)}';
      expect(await fileApp(h).importLicenseFile(padded), refused(LicenseFileError.malformed));
      expect(await fileApp(h).importLicenseFileBytes(utf8.encode(padded)), refused(LicenseFileError.malformed));
    });

    test('throws when it cannot be saved, and a removal that cannot be saved leaves the stored file', () async {
      final h = await Harness.create();
      final stored = await offlineFile(h);
      h.stored = stateOf({'licenseFile': stored});
      final app = fileApp(h);
      h.storage.failWrites = true;
      await expectLater(app.importLicenseFile(await offlineFile(h, {'fid': 'lf_3'})), throwsA(isA<FileSystemLikeError>()));
      await expectLater(app.removeLicenseFile(), throwsA(isA<FileSystemLikeError>()));
      expect(h.stored?.licenseFile, stored);
    });

    test('keeps the denylist it was made with, whatever the app does to its list after', () async {
      final h = await Harness.create();
      h.stored = stateOf({'licenseFile': await offlineFile(h)});
      final revoked = ['lf_9'];
      final app = fileApp(h, revoked: revoked);
      revoked.add('lf_1');
      expect(await app.status(), fileLicensed);
    });
  });

  group('a stored licence file that does not license this build', () {
    test('is revoked-file once an update lists it, with whose it is, and no entitlements', () async {
      final h = await Harness.create();
      h.stored = stateOf({
        'licenseFile': await offlineFile(h, {
          'ent': {'cloud': true}
        })
      });
      final app = fileApp(h, revoked: ['lf_0', 'lf_1']);
      expect(await app.status(), fileInvalid(LicenseReason.revokedFile));
      expect(await app.has('cloud'), isFalse);
    });

    test('is upgrade on a build newer than it covers, and outdated on one older', () async {
      final h = await Harness.create();
      h.stored = stateOf({'licenseFile': await offlineFile(h, {'minMajor': 2, 'major': 3})});
      expect(await fileApp(h, major: 4).status(), fileInvalid(LicenseReason.upgrade));
      expect(await fileApp(h, major: 1).status(), fileInvalid(LicenseReason.outdated));
    });

    test('reads a stored value that is not text as no file, as every field of the wrong type is', () async {
      // The reference reads one as tampered; this port (as the Swift port) reads
      // a stored field of the wrong type as absent. Either way it licenses nothing.
      final h = await Harness.create();
      final app = fileApp(h);
      for (final value in <Object?>[42, null, {'token': 'x'}]) {
        h.stored = stateOf({'licenseFile': value});
        expect(await app.status(), const LicenseStatus(LicenseState.unlicensed), reason: '$value');
      }
      h.stored = stateOf({'licenseFile': await offlineFile(h)});
      expect(await app.status(), fileLicensed);
    });

    test('is tampered when the stored token was edited, is a key file, which is never stored, or is empty', () async {
      final h = await Harness.create();
      final edited = payloadSwapped(await offlineFile(h), await offlineFile(h, {'major': 9}));
      final app = fileApp(h);
      for (final stored in [edited, await keyFile(h), '']) {
        h.stored = stateOf({'licenseFile': stored});
        expect(await app.status(), fileUnread(LicenseReason.tampered), reason: stored);
      }
    });

    test('survives a key rotation while the build carries the key that signed it, and is unknown-key after', () async {
      final h = await Harness.create();
      final next = await Signer.create();
      h.stored = stateOf({'licenseFile': await offlineFile(h)});
      expect(await fileApp(h, keys: [next.publicJwk, h.signer.publicJwk]).status(), fileLicensed);
      expect(await fileApp(h, keys: [next.publicJwk]).status(), fileUnread(LicenseReason.unknownKey));
    });
  });

  group('licence files and a call that has not finished', () {
    test('import and remove throw, writing nothing, while status() answers from the stored file, saying so', () async {
      final h = await Harness.create(
          httpTimeout: const Duration(milliseconds: 20), timing: const Timing(lockGrace: Duration(milliseconds: 20)));
      final token = await offlineFile(h);
      h.stored = stateOf({'licenseFile': token});
      h.storage.hangNextRead = true;
      final stuck = h.license.status();
      await expectLater(h.license.importLicenseFile(token), throwsA(isA<LicenseCallUnfinished>()));
      await expectLater(h.license.removeLicenseFile(), throwsA(isA<LicenseCallUnfinished>()));
      expect(await h.license.status(), fileLicensed.asStalled());
      expect(h.storage.writes, 0);
      stuck.ignore();
    });
  });

  group('the types an app handles', () {
    test('reads a container as strict UTF-8, every ill-formed sequence refused', () async {
      final token = await offlineFile(await Harness.create());
      List<int> file(List<int> note) => [...utf8.encode('# '), ...note, ...utf8.encode('\n$token\n')];
      const illFormed = [
        [0xC0, 0x80], [0xE0, 0x80, 0x80], [0xF0, 0x80, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
        [0xF5, 0x80, 0x80, 0x80], [0xFF], [0xE2, 0x82, 0x0A], [0xE2, 0x82, 0x41],
      ];
      for (final bytes in illFormed) {
        expect(licenseFileToken(file(bytes)), isNull, reason: '$bytes');
      }
      expect(licenseFileToken([...utf8.encode('$token\n# '), 0xE2, 0x82]), isNull);
      const wellFormed = [
        [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF], [0xEF, 0xBF, 0xBF], [0xF0, 0x90, 0x80, 0x80],
        [0xF4, 0x8F, 0xBF, 0xBF],
      ];
      for (final bytes in wellFormed) {
        expect(licenseFileToken(file(bytes)), token, reason: '$bytes');
      }
    });

    test("reads a leading byte-order mark, CRLF, notes and blank lines as the reference does", () async {
      final token = await offlineFile(await Harness.create());
      expect(licenseFileToken([0xEF, 0xBB, 0xBF, ...utf8.encode('# a note\r\n\r\n  $token \t\r\n# after\n')]), token);
      expect(licenseFileToken('#$token'), isNull);
    });

    test("the words are the reference's, and so are the extension and the media type", () {
      expect(LicenseFileError.values.map((e) => e.wire), [
        'malformed', 'not-a-license-file', 'bad-signature', 'unknown-key', 'wrong-product', 'revoked-file', 'upgrade', 'outdated',
      ]);
      expect(LicenseFileKind.values.map((e) => e.wire), ['key', 'offline']);
      expect(LicenseSource.values.map((e) => e.wire), ['file']);
      expect(licenseFileExtension, '.kglicense');
      expect(licenseFileMediaType, 'application/vnd.keygrant.license');
      expect(maxLicenseFileBytes, 16384);
    });

    test('only a file taken is imported', () {
      expect(const LicenseFileImported(LicenseFileKind.offline, ada).ok, isTrue);
      expect(const LicenseFileRefused(LicenseFileError.malformed).ok, isFalse);
      expect(const LicenseFileActivationFailed(LicenseError.network).ok, isFalse);
    });

    test('the stored file is licenseFile in the state, written and read by that name', () async {
      final token = await offlineFile(await Harness.create());
      expect(stateOf({'licenseFile': token}).toJson(), {'licenseFile': token});
      expect(stateOf({'licenseFile': token}).licenseFile, token);
    });
  });
}
