// What a deactivate reports of the journal, and metered uses behind a call
// that has not finished (the SDK contract, 12.6 and 7; meter-reports.test.ts,
// MeterReportTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/meters.dart' show maxPendingSpends;

import '../support/harness.dart';
import '../support/meter_support.dart';

Map<String, Object?> releaseBody(Harness h, [bool last = false]) =>
    last ? h.http.lastBodyOf('deactivate') : h.http.bodyOf('deactivate');

void releases(Harness h, [int status = 200]) => h.http.on('deactivate', (_) => HttpResponse(status, {}));

void main() {
  group('what a deactivate reports', () {
    test("carries the journal with the device's fingerprints, then clears it with the licence", () async {
      final h = await holdingJournal([entry(SpendKind.offline, 2, now0), entry(SpendKind.void_, 1, now0, id: spendId('B'))]);
      releases(h);
      expect((await h.license.deactivate()).released, isTrue);
      final body = releaseBody(h);
      expect([body['key'], body['activationId']], [key1, 'act_1']);
      expect([body['spends'], body['fingerprints']], [hasLength(2), hasLength(1)]);
      expect(body.containsKey('fingerprintKind'), isFalse);
      expect(h.storedJson.keys, isNot(anyOf(contains('spends'), contains('meterFigures'), contains('key'), contains('activationId'))));
    });

    test('sends exactly the key and the activation when there is nothing to report', () async {
      final figures = {'exports': const MeterFigure(left: 5, total: 100, offline: 10, resets: false, at: now0).toJson()};
      final h = await holding(state: {'meterFigures': figures});
      releases(h);
      await h.license.deactivate();
      expect(releaseBody(h), {'key': key1, 'activationId': 'act_1'});
      expect(h.storedJson.containsKey('meterFigures'), isFalse);
    });

    test('names no fingerprints when it cannot tell who the device is', () async {
      final h = await holding(fingerprinter: const BlindFingerprinter(), state: {'spends': journalJson([entry(SpendKind.offline, 1, now0)])});
      releases(h);
      await h.license.deactivate();
      expect(releaseBody(h)['spends'], hasLength(1));
      expect(releaseBody(h).containsKey('fingerprints'), isFalse);
    });

    test('clears the journal locally and says the seat may be held when the release got no 200', () async {
      for (final fail in [true, false]) {
        final h = await holdingJournal([entry(SpendKind.offline, 1, now0)]);
        if (fail) {
          h.http.fail = true;
        } else {
          releases(h, 503);
        }
        expect((await h.license.deactivate()).released, isFalse, reason: '$fail');
        expect(h.storedJson.containsKey('spends'), isFalse, reason: '$fail');
      }
    });

    test('reports what this process could not save, and forgets it with the rest', () async {
      final h = await holding();
      h.http.fail = true;
      h.storage.failWrites = true;
      await h.license.use('exports');
      h.storage.failWrites = false;
      h.http.fail = false;
      releases(h);
      await h.license.deactivate();
      expect(releaseBody(h)['spends'], hasLength(1));
      h.activates(await meteredLease(h));
      expect((await h.license.activate(key1)).ok, isTrue);
      expect((await h.license.status()).meters['exports']?.unsynced, 0);
      expect(h.journal, isEmpty);
    });

    test('whose state cannot be saved fails, keeping the key, and reports the journal again', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 2, now0)]);
      releases(h);
      h.storage.failWrites = true;
      await expectLater(h.license.deactivate(), throwsA(isA<FileSystemLikeError>()));
      expect(h.stored?.key, key1);
      h.storage.failWrites = false;
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.count('deactivate'), 2);
      expect(releaseBody(h, true)['spends'], hasLength(1));
      expect(h.stored?.key, isNull);
    });

    test('reports the first 64 of a longer journal, and clears every entry with the licence', () async {
      final spends = [for (var i = 0; i < maxPendingSpends + 6; i++) entry(SpendKind.unanswered, 1, longAgo, id: numbered(i, 'q'), meter: 'm$i')];
      final h = await holdingJournal(spends);
      releases(h);
      expect((await h.license.deactivate()).released, isTrue);
      final names = [for (final s in (releaseBody(h)['spends'] as List).cast<Map>()) s['meter']];
      expect([names.length, names.first, names.last], [maxPendingSpends, 'm0', 'm63']);
      expect(h.storedJson.containsKey('spends'), isFalse);
    });

    test('that cannot land what it holds goes with what is stored and its held reports, and fails with the key kept', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 4, longAgo, id: spendId('S'))]);
      h.http.fail = true;
      h.storage.failWrites = true;
      expect((await h.license.use('exports', 2) as UseSpent).offline, isTrue);
      expect(await h.license.use('renders'), useRefused(UseError.offlineLimit, 5));
      expect((await h.license.use('exports', 3) as UseSpent).offline, isTrue);
      expect(h.http.count('use'), 2);
      h.http.fail = false;
      releases(h);
      await expectLater(h.license.deactivate(), throwsA(isA<FileSystemLikeError>()));
      final sent = (releaseBody(h)['spends'] as List).cast<Map>();
      expect([for (final s in sent) '${s['meter']} ${s['n']} ${s.containsKey('void')}'], ['exports 4 false', 'exports 2 false', 'renders 1 true']);
      expect([sent[1]['id'], sent[2]['id']], [h.useBody(0)['id'], h.useBody(1)['id']]);
      expect(h.stored?.key, key1);
    });

    test("reports nothing for a seat that is another device's: the release is not its to make", () async {
      final h = await Harness.create(fingerprinter: ScriptedFingerprinter(const DeviceIdentity(fingerprint: 'fp-machine', kind: DeviceKind.machine)));
      final lease = await meteredLease(h, over: {'fp': 'f' * 64, 'fpk': 'machine'});
      h.hold(lease, {'lastSeen': now0, 'spends': journalJson([entry(SpendKind.offline, 1, now0)])});
      expect((await h.license.deactivate()).released, isTrue);
      expect(h.http.count('deactivate'), 0);
    });
  });

  group('behind a call that has not finished', () {
    test('status().meters works, saying so', () async {
      final h = await holding(
          httpTimeout: const Duration(milliseconds: 1500), timing: behind, state: {'spends': journalJson([entry(SpendKind.offline, 2, now0)])});
      h.http.on('validate', (_) => const HttpResponse(403, {'error': 'revoked'}));
      final release = h.storage.holdNextWrite();
      final held = h.storage.whenWritten(h.storage.writes + 1);
      final refreshing = h.license.refresh();
      await held;
      final later = await h.license.status();
      release();
      await refreshing;
      expect([later.state, later.stalled], [LicenseState.licensed, true]);
      expect([later.meters['exports']?.left, later.meters['exports']?.unsynced], [88, 2]);
    });

    test('a spend asks, saves nothing of the answer, and keeps the spend', () async {
      final h = await holding(httpTimeout: const Duration(milliseconds: 1500), timing: behind);
      h.http.on('validate', (_) => const HttpResponse(403, {'error': 'revoked'}));
      h.http.on('use', (_) => spent(89));
      final release = h.storage.holdNextWrite();
      final held = h.storage.whenWritten(h.storage.writes + 1);
      final refreshing = h.license.refresh();
      await held;
      final writes = h.storage.writes;
      expect(await h.license.use('exports'), spentLeft(89));
      expect(h.http.count('use'), 1);
      h.http.fail = true;
      expect(await h.license.use('exports', 2), spentLeft(88, offline: true));
      expect(h.storage.writes, writes);
      release();
      await refreshing;
      expect(h.stored?.refused, Refusal.revoked);
      await h.license.status();
      expect(kindsAndCounts(h.journal), ['unanswered 2']);
    });
  });
}
