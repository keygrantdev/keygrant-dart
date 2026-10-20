// A spend the allowance cannot cover while nothing answers: a void a minute,
// at most the cap of them, and the waits measured by both clocks (the SDK
// contract, 12.5; use.test.ts, UseHeldTests.swift). And the cases the
// reference's property test found (use.property.test.ts), as plain cases.

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/meters.dart' show maxPendingSpends, maxPendingVoids;

import '../support/harness.dart';
import '../support/meter_support.dart';

Matcher offlineLimit(int left) => useRefused(UseError.offlineLimit, left);

List<int> voidTimes(Harness h) => [for (final e in h.journal) if (e.isVoid) e.at];

void main() {
  group('a spend the allowance cannot cover, while nothing answers', () {
    test('asks once a minute, keeps at most the cap of voids, and leaves the journal its room', () async {
      final h = await holding();
      h.http.fail = true;
      for (var m = 0; m < 30; m++) {
        h.clock.value = now0 + m * minute;
        expect(await h.license.use('renders'), offlineLimit(5));
        expect(await h.license.use('renders'), offlineLimit(5));
      }
      expect(h.http.count('use'), 30);
      expect(voidTimes(h), [for (var i = 0; i < maxPendingVoids; i++) now0 + (14 + i) * minute]);
      expect(await h.license.use('exports', 3), spentLeft(87, offline: true));
      expect(h.journal, hasLength(maxPendingVoids + 1));
    });

    test('asks again when the device clock is set back below the void', () async {
      final h = await holding();
      h.http.fail = true;
      h.clock.value = now0 + 10 * minute;
      expect(await h.license.use('renders'), offlineLimit(5));
      h.clock.value = now0 + 10 * minute + 1000;
      expect(await h.license.use('renders'), offlineLimit(5));
      expect(h.http.count('use'), 1);
      h.http.fail = false;
      h.http.on('use', (_) => rendersSpent());
      h.clock.value = now0;
      expect(await h.license.use('renders'), spentLeft(4));
      expect(h.http.count('use'), 2);
    });

    test('is served at once when the server is back and its minute is over, not before', () async {
      final h = await holding();
      h.http.fail = true;
      expect(await h.license.use('renders'), offlineLimit(5));
      h.http.fail = false;
      h.http.on('use', (_) => rendersSpent(at: now0 + minute));
      h.clock.value = now0 + minute - 1;
      expect(await h.license.use('renders'), offlineLimit(5));
      expect(h.http.count('use'), 1);
      h.clock.value = now0 + minute;
      expect(await h.license.use('renders'), spentLeft(4));
    });

    test('asks whatever an unanswered spend of a covered meter waits for, and a void ahead of the clock', () async {
      final h = await holdingJournal([
        entry(SpendKind.unanswered, 1, now0 - 1000, id: spendId('U')),
        entry(SpendKind.void_, 1, now0 + day, id: spendId('V')),
      ]);
      h.http.on('use', (_) => rendersSpent());
      expect(await h.license.use('renders'), spentLeft(4));
    });

    test('a wait that cannot be measured leaves out only the entries ahead of the guarded clock', () async {
      final ahead = entry(SpendKind.unanswered, 1, now0 + 5 * day, id: spendId('Z'));
      final waiting = await holdingJournal([entry(SpendKind.unanswered, 1, now0 - 30000, id: spendId('A')), ahead]);
      waiting.http.on('use', (_) => spent(89));
      await waiting.license.use('exports');
      expect(waiting.http.count('use'), 0);
      final over = await holdingJournal([entry(SpendKind.unanswered, 1, now0 - 2 * minute, id: spendId('A')), ahead]);
      over.http.on('use', (_) => spent(89));
      await over.license.use('exports');
      expect(over.http.count('use'), 1);
    });
  });

  group('the cases the property test found', () {
    test('a spend held in memory is not reported under its own id: it joins the entry another process lands', () async {
      final h = await holding(state: waitRunning);
      await h.renewing();
      h.storage.failWrites = true;
      await h.license.use('exports', 2);
      h.storage.failWrites = false;
      h.stored = StoredState.fromJson({...h.storedJson, 'spends': journalJson([entry(SpendKind.offline, 1, now0 - 5, id: spendId('Y'))])});
      await h.license.refresh();
      final ids = [for (final r in (h.report(0) as List).cast<Map>()) r['id']];
      expect(ids, [spendId('Y')]);
      expect(kindsAndCounts(h.journal), ['offline 3']);
    });

    test('a landing that opens a void in a journal of sixteen voids replaces the oldest', () async {
      final voids = [for (var i = 0; i < maxPendingVoids; i++) entry(SpendKind.void_, 1, now0 - 30 * minute + i, id: numbered(i, 'v'), meter: 'renders')];
      final h = await holdingJournal(voids);
      h.http.fail = true;
      expect(await h.license.use('renders'), offlineLimit(5));
      expect(voidTimes(h), hasLength(maxPendingVoids));
      expect(h.journal.first.id, numbered(1, 'v'));
      expect(h.journal.last.at, now0);
    });

    test("a second spend meets the journal the first filled: its void finds no room, and the journal holds 64", () async {
      final spends = [for (var i = 0; i < maxPendingSpends - 1; i++) entry(SpendKind.unanswered, 1, longAgo, id: numbered(i, 'f'), meter: 'm$i')];
      final h = await holdingJournal(spends);
      h.http.fail = true;
      expect((await h.license.use('exports')).ok, isTrue);
      expect(h.journal, hasLength(maxPendingSpends));
      expect(await h.license.use('renders'), offlineLimit(5));
      expect(h.journal, hasLength(maxPendingSpends));
      expect(voidTimes(h), isEmpty);
    });

    test('offline, the unsynced spends of a meter never pass its allowance over a run of spends and waits', () async {
      final h = await holding(met: {'exports': {'left': 90, 'total': 100, 'offline': 7}});
      h.http.fail = true;
      var told = 0;
      for (var i = 0; i < 12; i++) {
        h.clock.value = now0 + i * 61000;
        final result = await h.license.use('exports', 1 + i % 3);
        if (result is UseSpent) told += 1 + i % 3;
        final unsynced = (await h.license.status()).meters['exports']!.unsynced;
        expect(unsynced, lessThanOrEqualTo(7), reason: 'step $i');
        expect(unsynced, told, reason: 'step $i');
      }
      expect(h.journal.length, lessThanOrEqualTo(maxPendingSpends));
      expect(voidTimes(h).length, lessThanOrEqualTo(maxPendingVoids));
    });

    test('once the server is back, it is told every spend the customer was told was made, once', () async {
      final h = await holding(met: {'exports': {'left': 90, 'total': 100, 'offline': 10}});
      h.http.fail = true;
      var told = 0;
      for (var i = 0; i < 6; i++) {
        h.clock.value = now0 + i * 30000;
        if (await h.license.use('exports', 2) is UseSpent) told += 2;
      }
      final recorded = <String, int>{};
      h.http.fail = false;
      h.http.on('validate', (body) {
        final confirmed = <Map<String, Object?>>[];
        for (final s in (body['spends'] as List? ?? const []).cast<Map>()) {
          if (s['void'] == true) {
            recorded.remove(s['id']);
            confirmed.add({'id': s['id'], 'void': true});
          } else {
            recorded[s['id'] as String] = s['n'] as int;
            confirmed.add({'id': s['id'], 'n': s['n']});
          }
        }
        return HttpResponse(200, {'spends': confirmed});
      });
      h.clock.value = now0 + 3 * hour;
      await h.license.refresh();
      expect(recorded.values.fold(0, (a, n) => a + n), told);
      expect(h.journal, isEmpty);
    });
  });

  group('two instances of the app over one state', () {
    test("never lose each other's spends: each save lands on the state as stored", () async {
      final h = await holding(met: {'exports': {'left': 1000, 'total': 1000, 'offline': 1000}});
      h.http.fail = true;
      final other = h.licenseFor(1);
      expect((await h.license.use('exports', 5) as UseSpent).offline, isTrue);
      expect((await other.use('exports', 7) as UseSpent).offline, isTrue);
      expect([for (final e in h.journal) '${e.kind.wire} ${e.n}']..sort(), ['offline 7', 'unanswered 5']);
      expect((await h.license.status()).meters['exports']?.unsynced, 12);
      expect((await other.status()).meters['exports']?.unsynced, 12);
    });

    test('a spend the other instance made counts against the allowance', () async {
      final h = await holding(state: waitRunning);
      final other = h.licenseFor(1);
      expect((await other.use('exports', 6)).ok, isTrue);
      expect(await h.license.use('exports', 6), offlineLimit(84));
      expect([for (final e in h.journal) if (!e.isVoid) e.n], [6]);
    });
  });
}
