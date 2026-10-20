// A purchase secret an earlier version stored: never sent, and left out of
// every save (retired.test.ts; RetiredTests.swift; merge.ts RETIRED_FIELDS).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';

import '../support/harness.dart';
import '../support/status_support.dart';

const retired = {
  'purchaseToken': 'q1w2e3r4t5y6u7i8o9p0a1s2d3f4g5h6j7k8l9z0x1c',
  'purchaseTokenAt': now0 - day,
  'claimAskedAt': now0 - 60000,
};

/// A licence over a real state file holding `json`, beside the harness's server and clock.
Future<(KeyGrantLicense, File)> overFile(Harness h, Map<String, Object?> json) async {
  final dir = await Directory.systemTemp.createTemp('keygrant-retired-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}${Platform.pathSeparator}$product.json');
  await file.writeAsString(jsonEncode(json));
  final license = KeyGrantLicense(LicenseConfig(
    product: product,
    apiBaseUrl: 'https://api.test/',
    publicJwk: h.signer.publicJwk,
    adapters: LicenseAdapters(
      storage: FileStorage.at(file.path),
      registry: h.stash,
      clock: h.clock,
      fingerprinter: const PlainFingerprinter(),
      http: h.http,
    ),
  ));
  return (license, file);
}

Future<Map<String, Object?>> onDisk(File file) async => jsonDecode(await file.readAsString()) as Map<String, Object?>;

void expectNoneSent(Harness h) {
  for (final call in h.http.calls) {
    expect(jsonEncode(call.body), isNot(contains(retired['purchaseToken'])), reason: call.action);
  }
}

void main() {
  test('is not read into the state', () {
    final state = StoredState.fromJson({'key': key1, ...retired});
    expect(state.toJson(), {'key': key1});
  });

  test('is never sent by status(), refresh() or startTrial(), and the first save leaves it out', () async {
    final h = await Harness.create();
    final trialLease = await h.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 5 * 86400);
    final (license, file) = await overFile(h, {
      'trialStart': now0 - 2 * day,
      'trialEndsAt': now0 + 5 * day,
      'trialLease': trialLease,
      'lastSeen': now0,
      ...retired,
    });
    h.http.on('trial', (_) => HttpResponse(200, {'trialStart': now0 - 2 * day, 'trialEndsAt': now0 + 5 * day, 'lease': trialLease}));
    expect((await license.status()).state, LicenseState.trial);
    await license.launchReportSettled();
    // The launch report's stamp is the first save, and it carries none of them.
    final saved = await onDisk(file);
    expect(saved['trialReportedAt'], now0);
    for (final field in retired.keys) {
      expect(saved.containsKey(field), isFalse, reason: field);
    }
    await license.refresh();
    await license.startTrial();
    expect(h.http.called('claim'), isFalse);
    expectNoneSent(h);
  });

  test('is left out by an activation, and a later deactivation activates nothing', () async {
    final h = await Harness.create();
    final (license, file) = await overFile(h, {'lastSeen': now0, ...retired});
    h.activates(await h.signer.lease('KEY-1'));
    h.http.on('deactivate', (_) => const HttpResponse(200, {'released': true}));
    expect(await license.activate('KEY-1'), isA<Activated>());
    final saved = await onDisk(file);
    for (final field in retired.keys) {
      expect(saved.containsKey(field), isFalse, reason: field);
    }
    expect((await license.deactivate()).released, isTrue);
    expect(js(await license.status()), {'state': 'unlicensed'});
    expect([for (final c in h.http.calls) c.action], ['activate', 'deactivate']);
    expectNoneSent(h);
  });

  test('is left out of a renewal saved over a licence that carried it', () async {
    final h = await Harness.create();
    final expired = await h.signer.lease(key1, ttlSeconds: 3600, at: now0 - 2 * day);
    final (license, file) = await overFile(h, {
      'key': key1,
      'activationId': 'act_1',
      'lease': expired,
      'checkedMajor': 1,
      'lastSeen': now0,
      ...retired,
    });
    final fresh = await h.signer.lease(key1);
    h.renews(fresh);
    expect(js(await license.status()), licensedJson);
    final saved = await onDisk(file);
    expect(saved['lease'], fresh);
    for (final field in retired.keys) {
      expect(saved.containsKey(field), isFalse, reason: field);
    }
    expectNoneSent(h);
  });
}
