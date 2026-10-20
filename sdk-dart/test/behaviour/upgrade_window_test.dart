// Upgrade protection: telling the server what this device runs
// (license.test.ts 'upgrade protection: telling the server what this device
// runs'; RefusalTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/lease.dart' show openMajor;

import '../support/harness.dart';
import '../support/status_support.dart';

/// An open lease (every version), carrying its upgrade window's end (ms) when given.
Future<String> openLease(Harness h, [int? windowEnds]) =>
    h.signer.lease(key1, major: openMajor, extra: {if (windowEnds != null) 'upgradeUntil': windowEnds ~/ 1000});

/// A fingerprinter that runs `onRead` each time it is read.
final class HookedFingerprinter extends Fingerprinter {
  HookedFingerprinter(this.onRead);
  void Function() onRead;
  @override
  Future<String> get() async {
    onRead();
    return 'fp-test';
  }
}

void main() {
  const window = now0 + 10 * day;

  test('refresh() sends the major it has just noted as kept, in the same validate', () async {
    final h = await Harness.create(major: 5);
    holding(h, await openLease(h, window), {'checkedMajor': 5, 'keptMajor': 2});
    h.renews(await openLease(h, window));
    expect((await h.license.refresh()).state, LicenseState.licensed);
    expect(h.http.bodyOf('validate')['keptMajor'], 5);
  });

  test('never lands a kept major noted for one activation on another saved meanwhile', () async {
    final fingerprinter = HookedFingerprinter(() {});
    final h = await Harness.create(major: 5, fingerprinter: fingerprinter);
    holding(h, await openLease(h, window), {'checkedMajor': 5});
    fingerprinter.onRead = () {
      fingerprinter.onRead = () {};
      store(h, {'key': 'SLUICE-OTHR-OTHR-OTHR-OTHR', 'activationId': 'act_2', 'lease': 'theirs', 'lastSeen': now0});
    };
    h.http.fail = true;
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(h.stored?.activationId, 'act_2');
    expect(h.stored?.keptMajor, isNull);
  });

  test('reports a newer major on an open lease online at once, and notes it was heard', () async {
    final h = await Harness.create(major: 3);
    holding(h, await openLease(h, window), {'checkedMajor': 2});
    final fresh = await openLease(h, window);
    h.renews(fresh);
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(h.http.bodyOf('validate'), containsPair('major', 3));
    expect(h.http.bodyOf('validate'), containsPair('key', key1));
    expect(h.stored?.lease, fresh);
    expect(h.stored?.checkedMajor, 3);
  });

  test('keeps the valid open lease, and the app running, when that check cannot reach the server', () async {
    final h = await Harness.create(major: 3);
    final lease = await openLease(h, window);
    holding(h, lease, {'checkedMajor': 2});
    h.http.fail = true;
    expect(await statusOf(h.license), licensedJson);
    expect(h.http.called('validate'), isTrue);
    expect(h.stored?.lease, lease);
    expect(h.stored?.checkedMajor, 2);
  });

  test('notes the run all the same when it cannot be saved: sent with the check, and licensed', () async {
    final h = await Harness.create(major: 3);
    final lease = await openLease(h, window);
    holding(h, lease, {'checkedMajor': 2});
    h.renews(lease);
    h.storage.failWrites = true;
    expect(await statusOf(h.license), licensedJson);
    expect(h.http.bodyOf('validate')['keptMajor'], 3);
  });

  test('does not ask when the server has already heard this major', () async {
    final h = await Harness.create(major: 3);
    holding(h, await openLease(h, window), {'checkedMajor': 3});
    await h.license.status();
    expect(h.http.calls, isEmpty);
  });

  test("notes the major it runs while the lease's window is open, and sends it on the next validate", () async {
    final h = await Harness.create(major: 3);
    holding(h, await openLease(h, window), {'checkedMajor': 3});
    await h.license.status();
    expect(h.stored?.keptMajor, 3);
    answers(h, 503, {'error': 'unavailable'});
    await h.license.refresh();
    expect(h.http.bodyOf('validate'), allOf(containsPair('major', 3), containsPair('keptMajor', 3)));
  });

  test('never lowers a kept major on a build older than the one noted', () async {
    final h = await Harness.create(major: 3);
    holding(h, await openLease(h, window), {'checkedMajor': 3, 'keptMajor': 4});
    await h.license.status();
    expect(h.stored?.keptMajor, 4);
  });

  test("stops noting at the window's end: a major first run after it is not kept", () async {
    final h = await Harness.create(major: 4);
    holding(h, await openLease(h, window), {'checkedMajor': 4, 'keptMajor': 3});
    h.clock.value = now0 + 11 * day;
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(h.stored?.keptMajor, 3);
  });

  test("counts the window's last second as closed, and the one before as open", () async {
    for (final (clock, kept) in [(window, 3), (window - 1000, 4)]) {
      final h = await Harness.create(major: 4);
      holding(h, await openLease(h, window), {'checkedMajor': 4, 'keptMajor': 3});
      h.clock.value = clock;
      await h.license.status();
      expect(h.stored?.keptMajor, kept, reason: 'at ${clock - window} ms');
    }
  });

  test('notes nothing on a lease that carries no window', () async {
    final h = await Harness.create(major: 3);
    holding(h, await openLease(h), {'checkedMajor': 3});
    await h.license.status();
    expect(h.stored?.keptMajor, isNull);
  });

  test("starts a key's notes afresh on activate, and drops them on deactivate", () async {
    final h = await Harness.create(major: 2);
    store(h, {'key': 'OLD-KEY', 'activationId': 'act_old', 'keptMajor': 7, 'checkedMajor': 7});
    h.activates(await openLease(h, window));
    await h.license.activate(key1);
    expect(h.stored?.key, key1);
    expect(h.stored?.checkedMajor, 2);
    expect(h.stored?.keptMajor, 2);
    h.http.on('deactivate', (_) => const HttpResponse(200, {'ok': true}));
    await h.license.deactivate();
    expect(h.stored?.keptMajor, isNull);
    expect(h.stored?.checkedMajor, isNull);
  });

  test("keeps the major it runs inside a renewed lease's upgrade window, and sends it next", () async {
    final h = await Harness.create(major: 2);
    holding(h, await h.signer.lease(key1, major: 2, ttlSeconds: 3600, at: now0 - 2 * day), {'checkedMajor': 2});
    final renewed = await h.signer.lease(key1, major: 2, extra: {'upgradeUntil': now0 ~/ 1000 + 30 * 86400});
    h.renews(renewed);
    expect(await statusOf(h.license), licensedJson);
    expect(h.stored?.lease, renewed);
    expect(h.stored?.keptMajor, 2);
    await h.license.refresh();
    expect(h.http.lastBodyOf('validate')['keptMajor'], 2);
  });
}
