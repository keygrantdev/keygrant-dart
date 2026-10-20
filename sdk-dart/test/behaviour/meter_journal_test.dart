// How the journal lands on the stored state, what a process keeps of what it
// could not save, and how a lease's `met` and the stored fields are read and
// written (the SDK contract, 12.3 and 12.4; meters.test.ts, MeterJournalTests.swift).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/journal.dart';
import 'package:keygrant/src/core/lease.dart' show metersOf;
import 'package:keygrant/src/core/meter_types.dart' show Confirmed;
import 'package:keygrant/src/core/meters.dart';

import '../support/harness.dart';
import '../support/meter_support.dart';

const about = 'act_1';

StoredState journal(List<SpendEntry> spends, {String? activation = about, Map<String, MeterFigure> figures = const {}}) =>
    StoredState.fromJson({
      if (activation != null) 'activationId': activation,
      'spends': journalJson(spends),
      'meterFigures': figures.map((k, f) => MapEntry(k, f.toJson())),
    });

JournalOp spend(JournalOpKind kind, String id, int n, {String meter = 'exports', int? limit, bool told = false, int at = now0, String a = about}) =>
    JournalOp.spend(kind, about: a, id: id, meter: meter, n: n, at: at, limit: limit, told: told);

JournalOp offlineOp(int n, {String meter = 'exports', int? limit, bool told = false}) =>
    spend(JournalOpKind.offline, spendId('N'), n, meter: meter, limit: limit, told: told);

List<String> ids(List<SpendEntry> j) => [for (final e in j) e.id];

List<SpendEntry> crowd(int count) =>
    [for (var i = 0; i < count; i++) entry(SpendKind.unanswered, 1, now0, id: numbered(i), meter: 'm$i')];

Map<String, BaseFigure> met(String text) => metersOf(jsonDecode(text));

void main() {
  group('landing a spend', () {
    test('grows one offline entry for each meter, and opens the others once by id', () {
      expect(journaled(journal([entry(SpendKind.offline, 3, now0)]), offlineOp(2), now0).spends, [entry(SpendKind.offline, 5, now0)]);
      final held = journal([entry(SpendKind.unanswered, 1, now0)]);
      expect(journaled(held, spend(JournalOpKind.unanswered, spendId('A'), 9), now0).spends, [entry(SpendKind.unanswered, 1, now0)]);
      expect(journaled(journal([entry(SpendKind.offline, 3, now0)]), offlineOp(1, meter: 'renders'), now0).spends, hasLength(2));
    });

    test('leaves an id already in the journal as it is, an offline entry included, before its limit is judged', () {
      final held = journal([entry(SpendKind.offline, 4, now0, id: spendId('B'))]);
      for (final kind in [JournalOpKind.unanswered, JournalOpKind.void_]) {
        final landed = journaled(held, spend(kind, spendId('B'), 9), now0);
        expect([landed.refused, landed.spends], [false, held.spends], reason: '$kind');
      }
      final limited = journaled(held, spend(JournalOpKind.unanswered, spendId('B'), 9, limit: 1), now0);
      expect([limited.refused, limited.spends], [false, held.spends]);
    });

    test("refuses a spend that would take its meter's unsynced past its limit, and holds a void to none", () {
      final held = journal(journalOfEveryKind);
      expect(journaled(held, offlineOp(5, limit: 10), now0).refused, isFalse);
      final refused = journaled(held, offlineOp(6, limit: 10), now0);
      expect([refused.refused, refused.spends], [true, held.spends]);
      expect(journaled(held, spend(JournalOpKind.void_, spendId('V'), 6, limit: 0), now0).refused, isFalse);
    });

    test('lands a spend the customer was told was made past its limit and the cap, and never refuses it', () {
      final landed = journaled(journal(crowd(maxPendingSpends)), offlineOp(1, told: true), now0);
      expect([landed.refused, landed.spends.length], [false, maxPendingSpends + 1]);
      expect(journaled(journal([entry(SpendKind.offline, 3, now0)]), offlineOp(9, limit: 5, told: true), now0).spends.first.n, 12);
    });

    test('keeps the cap of voids, a new one taking the place of the oldest, and never refuses for it', () {
      final voids = [for (var i = 0; i < maxPendingVoids; i++) entry(SpendKind.void_, 1, now0 - 1000 + i, id: numbered(i, 'v'))];
      final next = spend(JournalOpKind.void_, spendId('N'), 1);
      expect(journaled(journal(voids.skip(1).toList()), next, now0).spends, hasLength(maxPendingVoids));
      final replaced = journaled(journal(voids), next, now0);
      expect(replaced.refused, isFalse);
      expect(ids(replaced.spends), [...ids(voids.skip(1).toList()), spendId('N')]);
      final full = [...crowd(maxPendingSpends - maxPendingVoids), ...voids];
      final fullReplaced = journaled(journal(full), next, now0);
      expect([fullReplaced.refused, fullReplaced.spends.length], [false, maxPendingSpends]);
      expect(ids(fullReplaced.spends), isNot(contains(voids.first.id)));
      final crowded = [entry(SpendKind.void_, 1, now0, id: spendId('V')), ...crowd(maxPendingSpends - 1)];
      expect(journaled(journal(crowded), next, now0).refused, isTrue);
      final told = spend(JournalOpKind.void_, spendId('N'), 1, told: true);
      expect(journaled(journal(voids), told, now0).spends, replaced.spends);
      expect(journaled(journal(crowded), told, now0).refused, isTrue);
      final unansweredOp = spend(JournalOpKind.unanswered, spendId('N'), 1);
      expect(journaled(journal(voids), unansweredOp, now0).spends, hasLength(maxPendingVoids + 1));
    });

    test('refuses an append past 64 entries, and lets an open entry grow', () {
      final full = crowd(maxPendingSpends);
      expect(journaled(journal(full), offlineOp(1), now0).refused, isTrue);
      final grown = journaled(journal([entry(SpendKind.offline, 3, now0), ...full.skip(1)]), offlineOp(1), now0);
      expect([grown.refused, grown.spends.first.n], [false, 4]);
    });
  });

  group('confirming, figures, the seat and the horizon', () {
    List<SpendEntry> confirm(List<SpendEntry> spends, List<Confirmed> entries) =>
        journaled(journal(spends), JournalOp.confirmed(about, entries), now0).spends;

    test('drops an entry by the count the server recorded, a void by a void, and keeps what grew meanwhile', () {
      final held = entry(SpendKind.offline, 3, now0);
      expect(confirm([held], [Confirmed.count(held.id, 3)]), isEmpty);
      expect(confirm([held], [Confirmed.count(held.id, 9)]), isEmpty);
      final grown = entry(SpendKind.offline, 5, now0);
      expect(confirm([grown], [Confirmed.count(held.id, 3)]), [grown]);
      final voided = entry(SpendKind.void_, 3, now0);
      expect(confirm([voided], [Confirmed.voided(held.id)]), isEmpty);
      expect(confirm([voided], [Confirmed.count(held.id, 1)]), [voided]);
      final unansweredEntry = entry(SpendKind.unanswered, 3, now0);
      expect(confirm([unansweredEntry], [Confirmed.voided(held.id)]), [unansweredEntry]);
    });

    test('keeps the newer figure of each meter, and nothing about another activation', () {
      const stored = {'exports': MeterFigure(left: 70, total: 100, offline: 10, resets: false, at: now0)};
      int? left(String? activation, int at) => journaled(
              journal(const [], activation: activation, figures: stored),
              JournalOp.figures(about, {'exports': MeterFigure(left: 50, total: 100, offline: 10, resets: false, at: at)}),
              now0)
          .meterFigures['exports']
          ?.left;
      expect([left(about, now0 + 1), left(about, now0), left(about, now0 - 1)], [50, 70, 70]);
      expect([left('act_2', now0 + 1), left(null, now0 + 1)], [70, 70]);
    });

    test('clears both for another seat or a deactivation, and keeps them for the same seat', () {
      final held = journal([entry(SpendKind.offline, 1, now0)],
          figures: {'exports': const MeterFigure(left: 70, total: 100, offline: 10, resets: false, at: now0)});
      final other = journaled(held, const JournalOp.activated('act_2'), now0);
      expect([other.spends, other.meterFigures], [isEmpty, isEmpty]);
      final same = journaled(held, const JournalOp.activated(about), now0);
      expect([same.spends.length, same.meterFigures.length], [1, 1]);
      expect(journaled(StoredState.empty, const JournalOp.activated(about), now0).spends, isEmpty);
      final gone = journaled(held, const JournalOp.deactivated(), now0);
      expect([gone.spends, gone.meterFigures], [isEmpty, isEmpty]);
    });

    test('drops entries opened more than 180 days ago on any op that lands, and keeps those exactly that old', () {
      final old = entry(SpendKind.unanswered, 1, now0 - pendingMaxMs - 1, id: spendId('O'));
      final edge = entry(SpendKind.unanswered, 1, now0 - pendingMaxMs, id: spendId('E'));
      expect(ids(journaled(journal([old, edge]), offlineOp(1), now0).spends), [spendId('E'), spendId('N')]);
      expect(journaled(journal([old]), const JournalOp.confirmed(about, []), now0).spends, isEmpty);
      expect(journaled(journal([old]), const JournalOp.activated(about), now0).spends, isEmpty);
      final other = spend(JournalOpKind.offline, spendId('N'), 1, a: 'act_2');
      expect(journaled(journal([old]), other, now0).spends, [old]);
    });

    test('lands ops in order on a state, and is that state itself with none', () {
      final state = journal(const []);
      expect(landJournal(state, const [], now0).state, state);
      final landed = landJournal(state, [offlineOp(2), JournalOp.confirmed(about, [Confirmed.count(spendId('N'), 2)])], now0);
      expect(landed.state.toJson().containsKey('spends'), isFalse);
      expect(landed.refused, [false, false]);
    });
  });

  group('what a process keeps', () {
    JournalOp offlineOf(int n, String meter) =>
        spend(JournalOpKind.offline, numbered(n, 'q'), n, meter: meter, at: now0 + 1000 * n);
    JournalOp figureOp(int left, int at) =>
        JournalOp.figures(about, {'exports': MeterFigure(left: left, total: 100, offline: 10, resets: false, at: at)});
    JournalOp confirmedOp(int n) => JournalOp.confirmed(about, [Confirmed.count(spendId('A'), n)]);
    String shape(List<JournalOp> ops) => jsonEncode([
          for (final op in ops)
            {'kind': op.kind.name, 'id': op.id, 'n': op.n, 'at': op.at, 'meter': op.meter, 'about': op.about,
             'entries': [for (final c in op.entries) c.toJson()], 'figures': op.figures.map((k, f) => MapEntry(k, f.toJson()))}
        ]);

    test('folds offline spends of one meter, figures and confirmations, and nothing across another change', () {
      final folded = compacted([offlineOf(1, 'exports'), offlineOf(2, 'exports'), offlineOf(3, 'exports')]);
      expect(shape(folded), shape([spend(JournalOpKind.offline, numbered(1, 'q'), 6, at: now0 + 1000)]));
      expect(compacted([offlineOf(1, 'exports'), offlineOf(2, 'renders'), offlineOf(3, 'exports')]), hasLength(3));
      expect(shape(compacted([figureOp(70, now0), figureOp(50, now0 + 1)])), shape([figureOp(50, now0 + 1)]));
      expect(shape(compacted([figureOp(50, now0 + 1), figureOp(70, now0)])), shape([figureOp(50, now0 + 1)]));
      expect(shape(compacted([confirmedOp(2), confirmedOp(3)])), shape([confirmedOp(3)]));
      expect(shape(compacted([confirmedOp(3), confirmedOp(2)])), shape([confirmedOp(3)]));
      expect(compacted([offlineOf(1, 'exports'), const JournalOp.deactivated(), offlineOf(2, 'exports')]), hasLength(3));
      expect(compacted([offlineOf(1, 'exports'), spend(JournalOpKind.offline, spendId('N'), 2, a: 'act_2')]), hasLength(2));
      expect(compacted([offlineOf(1, 'exports'), const JournalOp.activated(about), offlineOf(2, 'exports')]), hasLength(3));
      expect(compacted([offlineOf(1, 'exports'), spend(JournalOpKind.void_, spendId('V'), 1), offlineOf(2, 'exports')]), hasLength(3));
      final both = compacted([confirmedOp(1), JournalOp.confirmed(about, [Confirmed.voided(spendId('A'))])]);
      expect([for (final c in both.single.entries) c.toJson()], [{'id': spendId('A'), 'n': 1}, {'id': spendId('A'), 'void': true}]);
    });

    test('what is folded lands as the ops it was folded from would', () {
      JournalOp offline(String letter, int n, int ago) => spend(JournalOpKind.offline, spendId(letter), n, at: now0 - ago);
      final ops = [offline('a', 1, 3000), offline('b', 2, 2000), offline('c', 4, 1000)];
      final base = journal(const []);
      final landed = landJournal(base, compacted(ops), now0).state;
      expect(landed, landJournal(base, ops, now0).state);
      expect(landed.spends, [entry(SpendKind.offline, 7, now0 - 3000, id: spendId('a'))]);
    });

    test('keeps only the newest voids in memory, and every other change', () {
      JournalOp voidOp(int i) => spend(JournalOpKind.void_, numbered(i, 'v'), 1);
      final ops = [for (var i = 0; i < 20; i++) voidOp(i)];
      final offline = offlineOp(1);
      ops.insert(5, offline);
      ops.add(const JournalOp.deactivated());
      final kept = boundedVoids(ops);
      final voids = kept.where((op) => op.kind == JournalOpKind.void_).toList();
      expect(voids, hasLength(maxPendingVoids));
      expect(voids.first.id, numbered(4, 'v'));
      expect([kept.contains(offline), kept.any((op) => op.kind == JournalOpKind.deactivated)], [true, true]);
      expect(boundedVoids(ops.sublist(16)), hasLength(ops.length - 16));
    });
  });

  group("a lease's met, read leniently", () {
    test('reads a met that is not an object as no meters', () {
      for (final text in ['null', '[]', '[{"left":1,"total":1,"offline":1}]', '"exports"', '7', 'true']) {
        expect(met(text), isEmpty, reason: text);
      }
    });

    test('drops a member whose figures are not non-negative whole numbers of at most 2^53 - 1', () {
      String meter(String left) => '{"exports":{"left":$left,"total":10,"offline":1}}';
      for (final kept in ['4', '4.0', '4e0', '0', '-0', '9007199254740991']) {
        expect(met(meter(kept)), hasLength(1), reason: kept);
      }
      for (final dropped in ['-1', '1.5', '0.5', '"4"', 'null', 'true', '[4]', '{}', '9007199254740992', '1e19', '18446744073709551615']) {
        expect(met(meter(dropped)), isEmpty, reason: dropped);
      }
      final both = met('{"a":{"left":4,"total":10,"offline":1},"b":{"left":-1,"total":10,"offline":1},"c":{"left":4,"total":10,"offline":1}}');
      expect(both.keys.toList()..sort(), ['a', 'c']);
    });

    test('reads resets as true only for JSON true', () {
      bool? resets(String value) => met('{"m":{"left":1,"total":1,"offline":0,"resets":$value}}')['m']?.resets;
      expect(resets('true'), isTrue);
      for (final other in ['false', 'null', '1', '"true"', '[true]', '{}', '0']) {
        expect(resets(other), isFalse, reason: other);
      }
    });

    test("keeps names as they are, the server's caps unenforced and a meter's other members ignored", () {
      final nine = [for (var i = 0; i < 9; i++) '"m$i":{"left":20,"total":10,"offline":1,"overage":3,"extra":{"a":1}}'].join(',');
      expect(met('{$nine}'), hasLength(9));
      final named = met('{"__proto__":{"left":4,"total":10,"offline":1},"":{"left":4,"total":10,"offline":1},"éxports":{"left":4,"total":10,"offline":1}}');
      expect(named.keys.toList()..sort(), ['', '__proto__', 'éxports']);
      expect(met('{"m":{"left":1,"total":9,"offline":0},"m":{"left":2,"total":9,"offline":0}}')['m']?.left, 2);
    });

    test('a figure out of range drops its member and never the lease', () async {
      final h = await Harness.create();
      final raw = await RawSigner.create();
      h.hold(await raw.lease('{"huge":{"left":1e400,"total":10,"offline":1},"kept":{"left":1,"total":2,"offline":0}}'), {'lastSeen': now0});
      final status = await raw.app(h).status();
      expect(status.state, LicenseState.licensed);
      expect(status.meters.keys, ['kept']);
    });

    test('a met claim that is null or any JSON is no meters, and the lease licenses', () async {
      for (final text in ['null', '[]', '7']) {
        final h = await Harness.create();
        final raw = await RawSigner.create();
        h.hold(await raw.lease(text), {'lastSeen': now0});
        final status = await raw.app(h).status();
        expect([status.state, status.meters], [LicenseState.licensed, isEmpty], reason: text);
      }
    });
  });

  group('the stored state', () {
    test('reads the journal leniently, and writes it back without what it dropped', () {
      final read = StoredState.fromJson(jsonDecode('''{"key":"$key1","spends":[
        {"id":"A","meter":"m","n":2,"at":5,"kind":"offline","extra":1},
        {"id":"B","meter":"m","n":0,"at":5,"kind":"offline"},
        {"id":"C","meter":"m","n":1,"at":-5,"kind":"offline"},
        {"id":"D","meter":"m","n":1,"at":5,"kind":"other"},
        {"id":"E","meter":3,"n":1,"at":5,"kind":"offline"},
        {"id":"F","meter":"m","n":1,"at":5.5,"kind":"void"},
        17],
        "meterFigures":{"m":{"left":1,"total":2,"offline":0,"resets":true,"at":9,"extra":true},
          "bad":{"left":1,"total":2,"offline":0,"at":-9},"worse":"x"}}'''));
      expect(read.spends, [const SpendEntry(id: 'A', meter: 'm', n: 2, at: 5, kind: SpendKind.offline)]);
      expect(read.toJson()['spends'], [{'id': 'A', 'meter': 'm', 'n': 2, 'at': 5, 'kind': 'offline'}]);
      expect(read.toJson()['meterFigures'], {'m': {'left': 1, 'total': 2, 'offline': 0, 'resets': true, 'at': 9}});
      for (final spends in <Object?>['junk', {}, 7, [null, 1], []]) {
        expect(StoredState.fromJson({'spends': spends}).toJson().containsKey('spends'), isFalse, reason: '$spends');
      }
    });

    test('round-trips the state through its JSON', () {
      final state = StoredState.fromJson({
        'key': key1, 'activationId': 'act_1',
        'spends': journalJson([entry(SpendKind.unanswered, 2, now0), entry(SpendKind.void_, 1, now0, id: spendId('V'))]),
        'meterFigures': {'exports': const MeterFigure(left: 70, total: 100, offline: 10, resets: true, at: now0).toJson()},
      });
      expect(StoredState.fromJson(jsonDecode(jsonEncode(state.toJson()))), state);
    });
  });

  group('the words and the status', () {
    test('every error is its word, and a result says what it is', () {
      expect(UseError.values.map((e) => e.wire), [
        'invalid-amount', 'no-meter', 'used-up', 'offline-limit', 'not-licensed', 'storage', 'revoked', 'upgrade', 'outdated', 'device',
      ]);
      expect(const UseSpent(89).ok, isTrue);
      expect(const UseSpent(88, offline: true).offline, isTrue);
      const used = UseRefused(UseError.usedUp, 1);
      expect([used.ok, used.left, used.error], [false, 1, UseError.usedUp]);
      expect(const UseRefused(UseError.storage).left, isNull);
    });

    test('a status counts its meters in its equality', () {
      const plain = LicenseStatus(LicenseState.licensed);
      final metered = plain.withMeters({'exports': const MeterStatus(left: 9, total: 10, offline: 1, unsynced: 1, resets: true)});
      expect(plain.withMeters(const {}), plain);
      expect(metered, isNot(plain));
      expect(metered, isNot(plain.withMeters({'exports': const MeterStatus(left: 8, total: 10, offline: 1, unsynced: 1, resets: true)})));
    });
  });
}

final journalOfEveryKind = [
  entry(SpendKind.offline, 3, now0),
  entry(SpendKind.unanswered, 2, now0, id: spendId('B')),
  entry(SpendKind.void_, 50, now0, id: spendId('C')),
  entry(SpendKind.offline, 9, now0, id: spendId('D'), meter: 'renders'),
];
