// use(meter, n) beside a disk that refuses, a second process and a call that
// has not finished: a spend the customer was told was made is kept in memory
// and counted everywhere, a request reports the journal as stored, and the
// allowance is judged again where a spend lands (the SDK contract, 12.4;
// use.test.ts, UseHeldTests.swift, UseProcessTests.swift).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/lease.dart' show openMajor;
import 'package:keygrant/src/core/meters.dart' show maxPendingSpends, maxPendingVoids;

import '../support/harness.dart';
import '../support/meter_support.dart';

Matcher offlineLimit(int left) => useRefused(UseError.offlineLimit, left);

/// A key holding `met`, its no-answer wait running (a spend the allowance covers asks nothing).
Future<Harness> waiting({
  Map<String, Object?> met = const {'exports': {'left': 90, 'total': 100, 'offline': 10}},
  Duration httpTimeout = const Duration(seconds: 15),
  Map<String, Object?> state = const {},
}) =>
    holding(met: met, httpTimeout: httpTimeout, timing: behind, state: {...waitRunning, ...state});

Map<String, Object?> theirY(int n) => {'id': spendId('Y'), 'meter': 'exports', 'n': n, 'at': now0 - 5};

List<SpendEntry> crowd(int count, [String letter = 'c']) =>
    [for (var i = 0; i < count; i++) entry(SpendKind.unanswered, 1, now0 - 100, id: numbered(i, letter), meter: 'm$i')];

void main() {
  group('a spend held in memory', () {
    test('is not reported until it has landed, so the entry it joins is reported with it once', () async {
      final h = await waiting();
      await h.renewing();
      h.storage.failWrites = true;
      expect(await h.license.use('exports', 2), spentLeft(88, offline: true));
      final shown = (await h.license.refresh()).meters['exports'];
      expect([shown?.left, shown?.unsynced], [88, 2]);
      expect(h.report(0), isNull);
      h.stored = StoredState.fromJson({...h.storedJson, 'spends': journalJson([entry(SpendKind.offline, 1, now0 - 5, id: spendId('Y'))])});
      h.storage.failWrites = false;
      await h.license.refresh();
      expect(h.report(1), [theirY(3)]);
    });

    test('is reported with a release once it has landed, as everything the journal holds', () async {
      final h = await waiting();
      h.http.on('deactivate', (_) => const HttpResponse(200, {}));
      h.storage.failWrites = true;
      await h.license.use('exports', 2);
      h.storage.failWrites = false;
      expect((await h.license.deactivate()).released, isTrue);
      final first = (h.http.bodyOf('deactivate')['spends'] as List).first as Map;
      expect([first['meter'], first['n']], ['exports', 2]);
    });

    test('an unanswered spend and a void open once by their ids; only the offline spends are withheld', () async {
      final h = await holding();
      await h.renewing();
      h.storage.failWrites = true;
      h.http.fail = true;
      expect(await h.license.use('exports', 2), spentLeft(88, offline: true));
      expect(await h.license.use('renders'), offlineLimit(5));
      expect(await h.license.use('exports'), spentLeft(87, offline: true));
      h.http.fail = false;
      await h.license.refresh();
      final report = h.report(0) as List;
      expect([for (final r in report.cast<Map>()) '${r['meter']} ${r['n']} ${r['void'] == true}'], ['exports 2 false', 'renders 1 true']);
    });

    test('a view that carried held spends is judged by what is stored, though a save in the same call landed them', () async {
      final h = await Harness.create();
      final lease = await meteredLease(h, over: {'model': 'perpetual', 'major': openMajor, 'upgradeUntil': (now0 + 10 * day) ~/ 1000});
      h.stored = StoredState.fromJson({'key': key1, 'activationId': 'act_1', 'lease': lease, 'lastSeen': now0, ...waitRunning});
      final flaky = Flaky(h, injectAt: 2);
      final app = h.appOver(flaky);
      await h.renewing(lease);
      expect(await app.use('exports', 2), spentLeft(88, offline: true));
      flaky.diskBack();
      await app.refresh();
      expect(h.report(0), [theirY(3)]);
    });

    test('does not make status ask at every call for spends held in memory that no request carries', () async {
      final h = await waiting();
      await h.renewing();
      h.storage.failWrites = true;
      await h.license.use('exports', 2);
      h.clock.value = now0 + 2 * minute;
      for (var i = 0; i < 3; i++) {
        await h.license.status();
      }
      expect(h.http.count('validate'), 0);
      h.storage.failWrites = false;
      await h.license.status();
      expect(h.http.count('validate'), 1);
    });

    test('is not reported with a use either, whose own spend is: the report is what is stored', () async {
      final h = await waiting(met: usualMeters);
      h.storage.failWrites = true;
      await h.license.use('exports', 2);
      h.http.on('use', (_) => rendersSpent());
      expect(await h.license.use('renders'), spentLeft(4));
      expect([h.useBody()['meter'], h.useBody()['n'], h.useBody().containsKey('spends')], ['renders', 1, false]);
    });

    test("starts the hour's wait after an answer only when the request carried a report", () async {
      final h = await waiting();
      await h.renewing();
      final flaky = Flaky(h);
      final app = h.appOver(flaky);
      expect(await app.use('exports', 2), spentLeft(88, offline: true));
      flaky.diskBack();
      await app.refresh();
      expect(h.report(0), isNull);
      expect(h.journal, hasLength(1));
      expect(h.stored?.backoffMs, isNot(hour));
      h.clock.value = now0 + 2 * minute;
      await app.status();
      expect(h.http.count('validate'), 2);
      expect(((h.report(1) as List).first as Map)['n'], 2);
    });

    test("starts the hour's wait when an answer confirms none of the report it carried", () async {
      final h = await holdingJournal([entry(SpendKind.offline, 2, longAgo)]);
      await h.renewing();
      await h.license.refresh();
      expect(h.report(0), hasLength(1));
      expect([h.stored?.backoffSince, h.stored?.backoffMs], [now0, hour]);
      expect(h.journal, hasLength(1));
      await h.license.status();
      await h.license.status();
      expect(h.http.count('validate'), 1);
    });
  });

  group('calls one at a time', () {
    test('runs two calls made together one after the other, each a spend of its own', () async {
      final h = await holding();
      h.http.fail = true;
      final [a, b] = await Future.wait([h.license.use('exports', 3), h.license.use('exports', 4)]);
      expect([a.ok, b.ok], [true, true]);
      expect({(a as UseSpent).left, (b as UseSpent).left}, {87, 83});
      expect(h.journal.fold(0, (s, e) => s + e.n), 7);
    });

    test('waits behind a status already running, and sees what it saved', () async {
      final h = await holding();
      final renewed = await meteredLease(h, met: {'exports': {'left': 60, 'total': 100, 'offline': 10}}, at: now0 + 1000);
      h.clock.value = now0 + 1000;
      final gate = Completer<void>();
      var validated = false;
      h.http.on('validate', (_) async {
        await gate.future;
        validated = true;
        return HttpResponse(200, {'lease': renewed});
      });
      final asked = <bool>[];
      h.http.on('use', (_) {
        asked.add(validated);
        return const HttpResponse(200, {'spent': true});
      });
      final refreshing = h.license.refresh();
      await h.http.whenCalled('validate');
      final spending = h.license.use('exports');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.http.count('use'), 0);
      gate.complete();
      await refreshing;
      expect(await spending, spentLeft(60));
      expect(asked, [true]);
    });

    test('lets a validate that was in flight across a spend keep its lease', () async {
      final h = await holding();
      final other = h.licenseFor(1);
      final renewed = await meteredLease(h, at: now0 + 1000);
      final gate = Completer<void>();
      h.http.on('validate', (_) async {
        await gate.future;
        return HttpResponse(200, {'lease': renewed});
      });
      h.http.on('use', (_) => spent(89, at: now0 + 2000));
      final validating = h.license.refresh();
      await h.http.whenCalled('validate');
      h.clock.value = now0 + 2000;
      expect(await other.use('exports'), spentLeft(89));
      expect(h.stored?.verdictAt, isNull);
      gate.complete();
      await validating;
      expect(h.stored?.lease, renewed);
    });

    test('a spend kept while a save is in flight is counted once beside the one that save carries', () async {
      final h = await waiting(met: {'exports': {'left': 90, 'total': 100, 'offline': 50}}, httpTimeout: const Duration(milliseconds: 1500));
      h.storage.failWrites = true;
      expect((await h.license.use('exports', 2) as UseSpent).offline, isTrue);
      h.storage.failWrites = false;
      h.http.fail = true;
      final release = h.storage.holdNextWrite();
      final held = h.storage.whenWritten(h.storage.writes + 1);
      final refreshing = h.license.refresh();
      await held;
      final second = await h.license.use('exports', 3);
      expect((second as UseSpent).offline, isTrue);
      release();
      await refreshing;
      await h.license.status();
      expect(h.journal.fold(0, (s, e) => s + e.n), 5);
      expect((await h.license.status()).meters['exports']?.unsynced, 5);
    });
  });

  group('a disk that keeps refusing', () {
    test('loses no spend of one meter however many it holds', () async {
      final h = await holding(met: {'exports': {'left': 1000000, 'total': 1000000, 'offline': 1000000}});
      h.http.fail = true;
      h.storage.failWrites = true;
      for (var i = 0; i < 200; i++) {
        expect((await h.license.use('exports')).ok, isTrue);
      }
      final shown = (await h.license.status()).meters['exports'];
      expect([shown?.left, shown?.unsynced], [1000000 - 200, 200]);
      h.storage.failWrites = false;
      await h.license.status();
      expect(h.journal.fold(0, (s, e) => s + e.n), 200);
    });

    test('keeps every spend of two meters that take turns, and lands each total when the disk is back', () async {
      const big = {'left': 1000, 'total': 1000, 'offline': 1000};
      final h = await holding(met: {'exports': big, 'renders': big});
      h.http.fail = true;
      h.storage.failWrites = true;
      for (var turn = 0; turn < 50; turn++) {
        expect((await h.license.use('exports')).ok, isTrue);
        expect((await h.license.use('renders', 2)).ok, isTrue);
      }
      final shown = (await h.license.status()).meters;
      expect([shown['exports']?.unsynced, shown['renders']?.unsynced], [50, 100]);
      h.storage.failWrites = false;
      await h.license.status();
      final totals = <String, int>{};
      for (final e in h.journal) {
        totals[e.meter] = (totals[e.meter] ?? 0) + e.n;
      }
      expect(totals, {'exports': 50, 'renders': 100});
    });

    test('keeps the newest voids in memory, and refuses no covered spend for them', () async {
      final h = await holding();
      h.http.fail = true;
      h.storage.failWrites = true;
      for (var m = 0; m < 20; m++) {
        h.clock.value = now0 + m * minute;
        expect(await h.license.use('renders'), offlineLimit(5), reason: 'minute $m');
      }
      expect(await h.license.use('exports', 3), spentLeft(87, offline: true));
      h.storage.failWrites = false;
      await h.license.status();
      expect([for (final e in h.journal) if (e.isVoid) e.at], [for (var i = 0; i < maxPendingVoids; i++) now0 + (4 + i) * minute]);
      expect([for (final e in h.journal) if (!e.isVoid) '${e.meter} ${e.n}'], ['exports 3']);
    });
  });

  group('the allowance, judged where the spend lands', () {
    test('refuses a spend that another process took the allowance from meanwhile, and keeps theirs', () async {
      final h = await waiting();
      final app = h.appOver(Racing(h, [entry(SpendKind.offline, 8, now0 - 5, id: spendId('T'))]));
      expect(await app.use('exports', 5), offlineLimit(82));
      expect(kindsAndCounts(h.journal), ['offline 8']);
      expect((await app.use('exports', 2) as UseSpent).offline, isTrue);
      expect([for (final e in h.journal) e.n], [10]);
    });

    test('holds a spend to what is left when that is below the allowance', () async {
      const met = {'exports': {'left': 2, 'total': 100, 'offline': 50}};
      final h = await waiting(met: met);
      final app = h.appOver(Racing(h, [entry(SpendKind.offline, 2, now0 - 5, id: spendId('T'))]));
      expect(await app.use('exports', 2), offlineLimit(0));
      expect(kindsAndCounts(h.journal), ['offline 2']);
      final alone = await waiting(met: met);
      expect(await alone.license.use('exports', 2), spentLeft(0, offline: true));
      expect(await alone.license.use('exports'), offlineLimit(0));
    });

    test('journals a void for a spend that was in doubt and is then refused at landing', () async {
      final h = await holding();
      h.http.fail = true;
      final app = h.appOver(Racing(h, [entry(SpendKind.offline, 8, now0 - 5, id: spendId('T'))]));
      expect(await app.use('exports', 5), offlineLimit(82));
      expect(kindsAndCounts(h.journal), ['offline 8', 'void 5']);
      expect(h.journal[1].id, h.useBody()['id']);
    });

    test('never takes back a spend the customer was told was made: it lands past the allowance', () async {
      final h = await waiting();
      h.storage.failWrites = true;
      expect(await h.license.use('exports', 6), spentLeft(84, offline: true));
      h.storage.failWrites = false;
      final spends = [entry(SpendKind.offline, 8, now0, id: spendId('T')), ...crowd(maxPendingSpends - 1)];
      h.stored = StoredState.fromJson({...h.storedJson, 'spends': journalJson(spends)});
      await h.license.status();
      expect(h.journal, hasLength(maxPendingSpends));
      expect([h.journal.first.id, h.journal.first.n], [spendId('T'), 14]);
      final shown = (await h.license.status()).meters['exports'];
      expect([shown?.unsynced, shown?.left], [14, 76]);
    });

    test('lands a spend the customer was told was made as a 65th entry when it opens one of its own', () async {
      final h = await waiting();
      h.storage.failWrites = true;
      expect((await h.license.use('exports', 2)).ok, isTrue);
      h.storage.failWrites = false;
      h.stored = StoredState.fromJson({...h.storedJson, 'spends': journalJson(crowd(maxPendingSpends))});
      await h.license.status();
      expect(h.journal, hasLength(maxPendingSpends + 1));
      expect([h.journal.last.meter, h.journal.last.n, h.journal.last.kind], ['exports', 2, SpendKind.offline]);
    });

    test('answers 0 left when the state cannot be read again just after the refusal', () async {
      final h = await waiting();
      final app = h.appOver(Racing(h, [entry(SpendKind.offline, 8, now0 - 5, id: spendId('T'))], failReadsAfter: true));
      expect(await app.use('exports', 5), offlineLimit(0));
      expect(kindsAndCounts(h.journal), ['offline 8']);
    });

    test('answers 0 left when the state as the landing found it has no figure for the meter any more', () async {
      final figure = {'credits': const MeterFigure(left: 20, total: 20, offline: 10, resets: false, at: now0).toJson()};
      final theirs = [entry(SpendKind.offline, 8, now0 - 5, id: spendId('T'), meter: 'credits')];
      final h = await waiting(met: usualMeters, state: {'meterFigures': figure});
      final shown = (await h.license.status()).meters['credits'];
      expect([shown?.left, shown?.offline], [20, 10]);
      expect(await h.appOver(Racing(h, theirs, dropFigures: true)).use('credits', 5), offlineLimit(0));
      expect(kindsAndCounts(h.journal), ['offline 8']);
      final kept = await waiting(met: usualMeters, state: {'meterFigures': figure});
      expect(await kept.appOver(Racing(kept, theirs)).use('credits', 5), offlineLimit(12));
    });
  });

  group('what an answer stamps', () {
    Future<Harness> unconfirmed(HttpResponse? answer) async {
      final h = await holding(state: {'verdictAt': 111});
      if (answer == null) {
        h.http.fail = true;
      } else {
        h.http.on('use', (_) => answer);
      }
      await h.license.use('exports');
      return h;
    }

    test('leaves verdictAt alone for a spend, used-up and an unknown meter', () async {
      final usedUp = HttpResponse(409, {'error': 'used-up', 'left': 0, 'meters': usualMeters, 'at': now0});
      for (final answer in [spent(89, at: now0 + 5), usedUp, const HttpResponse(404, {'error': 'unknown-meter'})]) {
        expect((await unconfirmed(answer)).stored?.verdictAt, 111, reason: '${answer.status}');
      }
    });

    test("sets it for a verdict and for a wait, as a validate's answer does", () async {
      expect((await unconfirmed(const HttpResponse(403, {'error': 'revoked'}))).stored?.verdictAt, now0);
      expect((await unconfirmed(null)).stored?.verdictAt, now0);
    });
  });

  test('a deactivate releases all the same over a state whose journal is not one, and writes none of it back', () async {
    final h = await holding(state: {'spends': 'junk', 'meterFigures': 7});
    h.http.on('deactivate', (_) => const HttpResponse(200, {}));
    expect((await h.license.deactivate()).released, isTrue);
    expect(h.http.bodyOf('deactivate'), {'key': key1, 'activationId': 'act_1'});
    expect(h.storedJson.keys, isNot(anyOf(contains('key'), contains('spends'), contains('meterFigures'))));
  });
}
