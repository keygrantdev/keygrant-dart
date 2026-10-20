// A running trial reports its launch (launch-report.test.ts): at most once a
// day, stamped first, nothing sent when the stamp cannot be saved, never
// awaited, and not made with a key held.

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/offline.dart' show trialReportMs;

import '../support/harness.dart';
import '../support/trials_support.dart';

/// A harness holding a running trial, with `more` on top.
Future<Harness> running({Map<String, Object?> more = const {}, Fingerprinter? fingerprinter, bool quickly = false}) async {
  final h = await Harness.create(
    fingerprinter: fingerprinter,
    timing: quickly ? quick : const Timing(),
    httpTimeout: quickly ? quickHttp : const Duration(seconds: 15),
  );
  storeJson(h, await runningTrial(h.signer, more));
  return h;
}

void main() {
  test('from status(), stamped first, then posted in the background, its answer not read', () async {
    final h = await running();
    h.http.on('trial', (_) => const HttpResponse(200, {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 + 30 * day}));
    expect(await h.license.status(), trialFor(5));
    expect(h.stored!.trialReportedAt, now0);
    await h.license.launchReportSettled();
    expect(h.http.calls.map((c) => c.action), ['trial']);
    expect(h.http.bodyOf('trial'), {'fingerprint': 'fp-test', 'clientStart': now0 - 2 * day});
    // The answer is not read: the stored trial is as it was.
    expect(h.stored!.trialStart, now0 - 2 * day);
    expect(h.stored!.trialEndsAt, now0 + 5 * day);
  });

  test('at most once a day', () async {
    final h = await running();
    await h.license.status();
    await h.license.launchReportSettled();
    h.clock.value = now0 + trialReportMs - 1;
    await h.license.status();
    expect(h.http.count('trial'), 1);
    h.clock.value = now0 + trialReportMs;
    await h.license.status();
    await h.license.launchReportSettled();
    expect(h.http.count('trial'), 2);
  });

  test('a startTrial() answer within the day counts as a report', () async {
    final h = await running(more: {'trialAt': now0 - day ~/ 2});
    await h.license.status();
    await h.license.launchReportSettled();
    expect(h.http.called('trial'), isFalse);
  });

  test('never holds up the launch: status() has answered by the time the report is sent', () async {
    final h = await running();
    h.http.hang = true;
    var answered = false;
    final answer = h.license.status().then((s) {
      answered = true;
      return s;
    });
    await h.http.whenCalled('trial');
    await Future<void>.delayed(Duration.zero);
    expect(answered, isTrue);
    expect(await answer, trialFor(5));
  });

  test("sends nothing from a device whose own fingerprint does not read, after saving the day's stamp", () async {
    final h = await running(
        fingerprinter: const IdentityFingerprinter(DeviceIdentity(fingerprint: null, alternates: ['fp-host'])));
    expect(await h.license.status(), trialFor(5));
    await h.license.launchReportSettled();
    expect(h.stored!.trialReportedAt, now0);
    expect(h.http.called('trial'), isFalse);
  });

  test("sends the fingerprint's kind, and the stored start without reading the stash", () async {
    final h = await running(
        fingerprinter: const IdentityFingerprinter(DeviceIdentity(fingerprint: 'fp-own', kind: DeviceKind.machine)));
    h.stash.start = now0 - 9 * day;
    await h.license.status();
    await h.license.launchReportSettled();
    expect(h.http.bodyOf('trial'), {'fingerprint': 'fp-own', 'fingerprintKind': 'machine', 'clientStart': now0 - 2 * day});
  });

  test('is bounded as a status check is', () async {
    final h = await running(quickly: true);
    h.http.hang = true;
    await h.license.status();
    await h.http.whenCalled('trial');
    expect(h.http.calls.single.timeout, quick.statusCheck);
    final (_, ms) = await timed(h.license.launchReportSettled());
    expect(ms, lessThan(5000));
  });

  test('never fails offline', () async {
    final h = await running();
    h.http.fail = true;
    expect(await h.license.status(), trialFor(5));
    await expectLater(h.license.launchReportSettled(), completes);
  });

  test('sends nothing when its stamp cannot be saved, so it is never sent twice in a day', () async {
    final h = await running();
    h.storage.failWrites = true;
    expect(await h.license.status(), trialFor(5));
    await h.license.launchReportSettled();
    expect(h.http.called('trial'), isFalse);
  });

  test('is not made by an expired trial', () async {
    final h = await Harness.create();
    storeJson(h, {'trialStart': now0 - 2 * day, 'trialEndsAt': now0 - 1, 'lastSeen': now0});
    await h.license.status();
    await h.license.launchReportSettled();
    expect(h.http.called('trial'), isFalse);
    expect(h.stored!.trialReportedAt, isNull);
  });

  test('is not made with a key held', () async {
    final h = await running(more: {'key': 'KEY-1'});
    await h.license.status();
    await h.license.launchReportSettled();
    expect(h.http.called('trial'), isFalse);
  });

  test('is not made behind a call that has not finished', () async {
    final h = await running(quickly: true);
    h.storage.hangNextRead = true;
    h.license.status().ignore();
    expect(await h.license.status(), trialFor(5, stalled: true));
    await h.license.launchReportSettled();
    expect(h.http.called('trial'), isFalse);
    expect(h.storage.writes, 0);
  });

  test('is due, and stamped, by the guarded clock ahead of the device clock', () async {
    final h = await Harness.create();
    const ahead = now0 + 2 * day;
    storeJson(h, {
      'trialStart': now0 - 2 * day,
      'trialEndsAt': now0 + 30 * day,
      'trialLease': await trialLeaseOf(h.signer, days: 30),
      'trialReportedAt': now0 - 3600000,
      'lastSeen': ahead,
    });
    expect((await h.license.status()).state, LicenseState.trial);
    await h.license.launchReportSettled();
    expect(h.http.count('trial'), 1);
    expect(h.stored!.trialReportedAt, ahead);
  });
}
