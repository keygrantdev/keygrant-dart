// User-locked keys (the SDK contract, section 11; user-lock.test.ts,
// UserLockTests.swift): what activate() and importLicenseFile() send for the
// address and code a person typed, each word the server refuses a new device
// with, and everything that never carries them.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/wire.dart' show maxEmail;

import '../support/files_support.dart';
import '../support/harness.dart';

const words = {
  'user-email-required': LicenseError.userEmailRequired,
  'user-email-mismatch': LicenseError.userEmailMismatch,
  'user-code-required': LicenseError.userCodeRequired,
  'user-code-invalid': LicenseError.userCodeInvalid,
  'too-many-codes': LicenseError.tooManyCodes,
  'too-many-attempts': LicenseError.tooManyAttempts,
  'try-again': LicenseError.tryAgain,
};

/// A harness whose server activates any key with a lease for `key1`.
Future<Harness> activating() async {
  final h = await Harness.create();
  h.activates(await leaseTo3(h));
  return h;
}

/// A harness whose server refuses every activation with `word`.
Future<Harness> refusing(String word, {int status = 403}) async {
  final h = await Harness.create();
  h.http.on('activate', (_) => HttpResponse(status, {'error': word}));
  return h;
}

Matcher failed(LicenseError e) => isA<ActivateFailed>().having((r) => r.error, 'error', e);
Matcher notActivated(LicenseError e) => isA<LicenseFileActivationFailed>().having((r) => r.error, 'error', e);

void main() {
  group('activate with an address and a code', () {
    test('sends what the person typed, trimmed, beside the key, and nothing when they typed none', () async {
      final h = await activating();
      expect((await h.license.activate(key1)).ok, isTrue);
      expect(h.http.bodyOf('activate').keys, isNot(anyOf(contains('email'), contains('code'))));
      await h.license.activate(key1, email: '  Mara@Studio.example\n', code: ' 123 456 ');
      final body = h.http.lastBodyOf('activate');
      expect([body['key'], body['email'], body['code']], [key1, 'Mara@Studio.example', '123456']);
    });

    test('treats a blank address or code as none, and sends the one there is alone', () async {
      final h = await refusing('user-email-required');
      await h.license.activate(key1, email: '   ', code: '');
      expect(h.http.lastBodyOf('activate').keys, isNot(anyOf(contains('email'), contains('code'))));
      await h.license.activate(key1, email: 'mara@studio.example');
      expect(h.http.lastBodyOf('activate')['email'], 'mara@studio.example');
      expect(h.http.lastBodyOf('activate').containsKey('code'), isFalse);
      await h.license.activate(key1, code: '123456');
      expect(h.http.lastBodyOf('activate')['code'], '123456');
      expect(h.http.lastBodyOf('activate').containsKey('email'), isFalse);
    });

    test("answers each word of the server as its own error, whatever the status", () async {
      for (final MapEntry(key: word, value: error) in words.entries) {
        for (final status in [403, 429, 503]) {
          final h = await refusing(word, status: status);
          expect(await h.license.activate(key1, email: 'mara@studio.example'), failed(error), reason: '$status $word');
        }
        expect(error.wire, word);
      }
    });

    test("answers a locked key's first ask, with the key alone, as the error that asks for the address", () async {
      final h = await refusing('user-email-required');
      expect(await h.license.activate(key1), failed(LicenseError.userEmailRequired));
    });

    test('answers a rate limit or an outage that is not a lock word as network, as it always did', () async {
      for (final (status, word) in [(429, 'rate-limited'), (503, 'unavailable'), (500, 'internal'), (403, 'user-something-new'), (403, 'Try-Again')]) {
        final h = await refusing(word, status: status);
        expect(await h.license.activate(key1, email: 'mara@studio.example'), failed(LicenseError.network), reason: '$status $word');
      }
      final down = await Harness.create();
      down.http.fail = true;
      expect(await down.license.activate(key1, email: 'mara@studio.example'), failed(LicenseError.network));
    });

    test('stores nothing about the address, the code or a refusal', () async {
      final h = await refusing('user-code-required');
      expect(await h.license.activate(key1, email: 'mara@studio.example', code: '123456'), failed(LicenseError.userCodeRequired));
      expect(h.stored, isNull);
      expect(h.storage.writes, 0);
      final ok = await activating();
      expect((await ok.license.activate(key1, email: 'mara@studio.example', code: '123456')).ok, isTrue);
      final text = jsonEncode(ok.storedJson);
      expect(text, contains(key1));
      expect(text, isNot(anyOf(contains('studio'), contains('123456'))));
      expect(await ok.license.status(), keyLicensed);
    });

    test('refuses an address longer than any and a code that is not six digits before the server is asked', () async {
      final h = await refusing('user-email-required');
      final tooLong = '${'a' * maxEmail}@b.example';
      expect(await h.license.activate(key1, email: tooLong), failed(LicenseError.userEmailMismatch));
      expect(await h.license.activate(key1, email: 'a@b.example', code: '12345'), failed(LicenseError.userCodeInvalid));
      expect(await h.license.activate(key1, email: 'x' * 300, code: 'nope'), failed(LicenseError.userEmailMismatch));
      expect(await h.license.activate('', email: 'x' * 300), failed(LicenseError.invalidKey));
      expect(await h.license.activate(key1, email: '', code: '12'), failed(LicenseError.userCodeInvalid));
      expect(h.http.called('activate'), isFalse);
    });
  });

  group('what never carries them', () {
    test('sends neither to validate, deactivate or a trial, even after an activation that carried them', () async {
      final h = await activating();
      h.renews(await leaseTo3(h));
      h.http.on('deactivate', (_) => const HttpResponse(200, {}));
      expect((await h.license.activate(key1, email: 'mara@studio.example', code: '123456')).ok, isTrue);
      await h.license.refresh();
      await h.license.deactivate();
      await h.license.startTrial();
      for (final call in h.http.calls.where((c) => c.action != 'activate')) {
        expect(call.body.containsKey('email') || call.body.containsKey('code'), isFalse, reason: call.action);
      }
      expect(h.http.count('validate'), 1);
      expect(h.http.count('deactivate'), 1);
      expect(h.http.count('trial'), greaterThan(0));
    });
  });

  group('a key file', () {
    test("asks a key file's key with the same address and code, and its answers come back as activate's", () async {
      final h = await refusing('user-code-required');
      final app = fileApp(h);
      final file = fileText(await keyFile(h));
      expect(await app.importLicenseFile(file, email: ' Ada@Example.com ', code: '123 456'), notActivated(LicenseError.userCodeRequired));
      final body = h.http.bodyOf('activate');
      expect([body['key'], body['email'], body['code']], [key1, 'Ada@Example.com', '123456']);
      expect(await app.importLicenseFile(file), notActivated(LicenseError.userCodeRequired));
      expect(h.http.lastBodyOf('activate').keys, isNot(anyOf(contains('email'), contains('code'))));
      expect(h.stored, isNull);
    });

    test("takes a key file's options as bytes too", () async {
      final h = await refusing('user-email-required');
      final bytes = utf8.encode(fileText(await keyFile(h)));
      expect(await fileApp(h).importLicenseFileBytes(bytes, email: 'ada@example.com'), notActivated(LicenseError.userEmailRequired));
      expect(h.http.bodyOf('activate')['email'], 'ada@example.com');
    });

    test('takes a key file whose key activates with the options, sending them normalised and storing neither', () async {
      final h = await activating();
      final result = await fileApp(h).importLicenseFile(fileText(await keyFile(h)), email: '  Mara@Studio.example ', code: ' 123 456 ');
      expect(result, isA<LicenseFileImported>().having((r) => r.licensedTo, 'to', const LicensedTo(email: adaEmail)));
      final body = h.http.bodyOf('activate');
      expect([body['key'], body['email'], body['code']], [key1, 'Mara@Studio.example', '123456']);
      final text = jsonEncode(h.storedJson).toLowerCase();
      expect(text, contains(key1.toLowerCase()));
      for (final typed in ['mara@', 'studio.example', '123456', '123 456', 'example.com']) {
        expect(text, isNot(contains(typed)), reason: typed);
      }
    });

    test("judges a key file's key before the address, and the address before the code", () async {
      final h = await refusing('user-email-required');
      final app = fileApp(h);
      final long = 'x' * 300;
      expect(await app.importLicenseFile(fileText(await keyFile(h)), email: long, code: 'nope'), notActivated(LicenseError.userEmailMismatch));
      final blank = await keyFile(h, {'sub': ' '});
      expect(await app.importLicenseFile(fileText(blank), email: long, code: 'nope'), notActivated(LicenseError.invalidKey));
      expect(h.http.called('activate'), isFalse);
    });

    test('refuses a file that is no licence file before any key is asked for, whatever comes with it', () async {
      final h = await Harness.create();
      final result = await h.license.importLicenseFile('not a file', email: 'mara@studio.example');
      expect(result, isA<LicenseFileRefused>().having((r) => r.error, 'error', LicenseFileError.malformed));
      expect(h.http.called('activate'), isFalse);
    });

    test('ignores the options for an offline file, and asks nothing', () async {
      final h = await Harness.create();
      final taken = await fileApp(h).importLicenseFile(fileText(await offlineFile(h)), email: 'x' * 300, code: 'nope');
      expect(taken, isA<LicenseFileImported>().having((r) => r.licensedTo, 'to', ada));
      expect(h.http.calls, isEmpty);
    });
  });
}
