// The decisions under use() and status().meters, by the rule each states,
// straight through the functions the engine decides with (the SDK contract,
// section 12; meters.test.ts, MeterRulesTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/jws.dart' show b64urlDecode;
import 'package:keygrant/src/core/meter_types.dart' show Confirmed;
import 'package:keygrant/src/core/meters.dart';
import 'package:keygrant/src/core/use_outcome.dart';

import '../support/harness.dart';
import '../support/meter_support.dart';

String asked(String meter, int n) => switch (askedFor(meter, n)) {
      AskedFor(refused: final refused?) => refused.wire,
      final a => '${a.meter} ${a.n}',
    };

BaseFigure figure(int left, int total, int offline, [bool resets = false]) =>
    BaseFigure(left: left, total: total, offline: offline, resets: resets);

final usual = {'exports': figure(90, 100, 10)};

final journalOfEveryKind = [
  entry(SpendKind.offline, 4, now0),
  entry(SpendKind.unanswered, 3, now0, id: spendId('B')),
  entry(SpendKind.void_, 50, now0, id: spendId('C')),
  entry(SpendKind.offline, 9, now0, id: spendId('D'), meter: 'renders'),
];

List<SpendEntry> unanswered(int k, {required int ago}) =>
    [for (var i = 0; i < k; i++) entry(SpendKind.unanswered, 1, now0 - (i == k - 1 ? ago : ago + hour), id: numbered(i))];

bool asks(Map<String, Object?> state, {int clockNow = now0, int now = now0, required bool covered}) =>
    useAsksNow(state: StoredState.fromJson(state), clockNow: clockNow, now: now, covered: covered);

Map<String, Object?> waitingSince(int since, int ms) => {'backoffSince': since, 'backoffMs': ms};

Map<String, Object?> spendsOfJson(List<SpendEntry> spends) => {'spends': journalJson(spends)};

UseOutcome outcome(HttpResponse? response) =>
    useOutcome(response: response, askedAt: now0, major: 3, kind: DeviceKind.machine, ownClaim: 'c');

void main() {
  group('what is asked', () {
    test('takes a whole number from 1 to the bound, and judges the amount before the code', () {
      expect(asked('exports', 1), 'exports 1');
      expect(asked('exports', maxMeterUses), 'exports $maxMeterUses');
      for (final n in [0, -1, maxMeterUses + 1, 1 << 53]) {
        expect(asked('exports', n), 'invalid-amount', reason: '$n');
      }
      expect(asked('', 0), 'invalid-amount');
      expect(asked('', 1), 'no-meter');
    });

    test('counts a code in UTF-16 units: 32 are a code, 33 are not, a surrogate pair is two', () {
      expect(asked('x' * 32, 1), endsWith(' 1'));
      expect(asked('x' * 33, 1), 'no-meter');
      expect(asked('${'x' * 30}\u{1F600}', 1), endsWith(' 1'));
      expect(asked('${'x' * 31}\u{1F600}', 1), 'no-meter');
      expect(asked('\u{1F600}' * 16, 1), endsWith(' 1'));
      expect(asked('\u{1F600}' * 17, 1), 'no-meter');
    });

    test('makes an id of 22 characters of base64url, of 16 bytes, never the same twice', () {
      final ids = [for (var i = 0; i < 500; i++) newSpendId()];
      expect(ids.toSet(), hasLength(ids.length));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
        expect(b64urlDecode(id), hasLength(16));
      }
    });
  });

  group('the base figures', () {
    const iat = 1790000000;
    final met = {'exports': figure(90, 100, 10), 'renders': figure(5, 5, 0, true)};

    test("are the lease's when nothing is stored, and a stored figure's from the lease's own second on", () {
      expect(figuresOf(met, iat, const {}), met);
      for (final (at, left) in [(iat * 1000, 40), (iat * 1000 + 999, 40), (iat * 1000 - 1, 90)]) {
        final stored = {'exports': MeterFigure(left: 40, total: 100, offline: 10, resets: false, at: at)};
        expect(figuresOf(met, iat, stored)['exports']?.left, left, reason: '$at');
      }
    });

    test("a stored figure replaces the lease's whole member", () {
      final stored = {'exports': const MeterFigure(left: 7, total: 50, offline: 3, resets: true, at: 2000000000000)};
      expect(figuresOf({'exports': figure(90, 100, 10)}, 1, stored)['exports'], figure(7, 50, 3, true));
    });

    test('names a meter only a newer stored figure names, and drops one the newest lease no longer names', () {
      final stored = {
        'added': const MeterFigure(left: 7, total: 7, offline: 1, resets: false, at: iat * 1000 + 1),
        'gone': const MeterFigure(left: 7, total: 7, offline: 1, resets: false, at: iat * 1000 - 1),
      };
      expect(figuresOf({'exports': figure(90, 100, 10)}, iat, stored).keys.toList()..sort(), ['added', 'exports']);
      expect(figuresOf(null, iat, const {}), isEmpty);
    });
  });

  group("the status's meters", () {
    test('take the unsynced spends off left, count no void, and never go below 0', () {
      expect(meterStatusOf({'exports': figure(90, 100, 10), 'renders': figure(5, 5, 0, true)}, journalOfEveryKind), {
        'exports': const MeterStatus(left: 83, total: 100, offline: 10, unsynced: 7, resets: false),
        'renders': const MeterStatus(left: 0, total: 5, offline: 0, unsynced: 9, resets: true),
      });
    });
  });

  group('a spend with no answer', () {
    test('is allowed up to the allowance and up to what is left, and answers what is left after it', () {
      expect(offlineSpend(usual, const [], 'exports', 10).toJson(), {'ok': true, 'left': 80, 'limit': 10});
      expect(offlineSpend(usual, [entry(SpendKind.offline, 4, now0)], 'exports', 6).toJson(), {'ok': true, 'left': 80, 'limit': 10});
      expect(offlineSpend({'exports': figure(4, 100, 10)}, const [], 'exports', 4).toJson(), {'ok': true, 'left': 0, 'limit': 4});
    });

    test('is refused past either, with what is left, and always for an allowance of 0', () {
      Map<String, Object?> limit(int left) => {'ok': false, 'error': 'offline-limit', 'left': left};
      expect(offlineSpend(usual, const [], 'exports', 11).toJson(), limit(90));
      expect(offlineSpend({'exports': figure(4, 100, 10)}, const [], 'exports', 5).toJson(), limit(4));
      expect(offlineSpend({'exports': figure(90, 100, 0)}, const [], 'exports', 1).toJson(), limit(90));
      expect(offlineSpend({'exports': figure(5, 100, 50)}, [entry(SpendKind.offline, 12, now0)], 'exports', 1).toJson(), limit(0));
    });

    test('counts the unsynced of its own meter of both kinds, never a void, and knows no meter without a figure', () {
      expect(offlineSpend(usual, journalOfEveryKind, 'exports', 3).ok, isTrue);
      expect(offlineSpend(usual, journalOfEveryKind, 'exports', 4).toJson(), {'ok': false, 'error': 'offline-limit', 'left': 83});
      expect(offlineSpend(usual, const [], 'credits', 1).error, UseError.noMeter);
      expect(offlineSpend(usual, const [], 'constructor', 1).error, UseError.noMeter);
    });
  });

  group('when use asks', () {
    test('every time but while a no-answer wait runs on the device clock', () {
      expect(asks({}, covered: true), isTrue);
      expect(asks(waitingSince(now0 - 1000, 60000), covered: true), isFalse);
      expect(asks(waitingSince(now0 - 60000, 60000), covered: true), isTrue);
      expect(asks(waitingSince(now0 + 1000, 60000), covered: true), isTrue);
      expect(asks(waitingSince(now0 - 1000, hour), covered: true), isTrue);
    });

    test('waits a minute after one unanswered spend, doubling with each to an hour from the seventh on', () {
      final minutes = [1, 2, 4, 8, 16, 32, 60, 60, 60];
      for (var i = 0; i < minutes.length; i++) {
        expect(journalWaiting(unanswered(i + 1, ago: minutes[i] * minute - 1), now0), isTrue, reason: '${i + 1}');
        expect(journalWaiting(unanswered(i + 1, ago: minutes[i] * minute), now0), isFalse, reason: '${i + 1} over');
      }
      expect(journalWaiting(unanswered(64, ago: hour), now0), isFalse);
      expect(journalWaiting(unanswered(maxPendingSpends, ago: hour - 1), now0), isTrue);
      expect(journalWaiting([for (var i = 0; i < 10000; i++) entry(SpendKind.unanswered, 1, now0 - hour + 1, id: numbered(i))], now0), isTrue);
    });

    test('counts a void toward the wait, an offline spend not, and goes by the newest entry whatever the order', () {
      expect(journalWaiting([entry(SpendKind.void_, 1, now0 - 1000)], now0), isTrue);
      expect(journalWaiting([entry(SpendKind.offline, 1, now0)], now0), isFalse);
      final olderLast = [entry(SpendKind.unanswered, 1, now0 - 1000, id: spendId('a')), entry(SpendKind.unanswered, 1, now0 - 3 * hour, id: spendId('b'))];
      expect(journalWaiting(olderLast, now0), isTrue);
    });

    test("judges the journal's wait by the guarded clock, and the other by the device clock", () {
      const tenDays = 10 * day;
      expect(asks(spendsOfJson(unanswered(1, ago: 2 * minute)), clockNow: now0 - tenDays, covered: true), isTrue);
      final both = {...waitingSince(now0 - tenDays - 1000, 60000), ...spendsOfJson(unanswered(1, ago: 2 * minute))};
      expect(asks(both, clockNow: now0 - tenDays, covered: true), isFalse);
    });

    test('asks for a spend the allowance would refuse whatever the waits, and one it covers only when no wait runs', () {
      final state = {...waitingSince(now0 - 1000, 60000), ...spendsOfJson(unanswered(1, ago: 1000))};
      expect(asks(state, covered: true), isFalse);
      expect(asks(state, covered: false), isTrue);
      expect(asks({}, covered: false), isTrue);
    });

    test('gives the uncovered spend a wait of its own: a void opened less than a minute ago, ahead of neither clock', () {
      List<SpendEntry> voided(int at) => [entry(SpendKind.void_, 1, at)];
      expect(voidWaiting(voided(now0 - 60000 + 1), now0, now0), isTrue);
      expect(voidWaiting(voided(now0 - 60000), now0, now0), isFalse);
      expect(voidWaiting(voided(now0 + 1), now0, now0), isFalse);
      expect(voidWaiting([entry(SpendKind.unanswered, 1, now0), entry(SpendKind.offline, 1, now0)], now0, now0), isFalse);
      expect(asks({...waitingSince(now0 - 1000, 60000), ...spendsOfJson(voided(now0 - 1000))}, covered: false), isFalse);
      expect(asks(spendsOfJson(unanswered(1, ago: 1000)), covered: false), isTrue);
    });

    test('needs the device clock at or after the void too', () {
      final voided = [entry(SpendKind.void_, 1, now0 - 1000)];
      expect(voidWaiting(voided, now0, now0 - 1000), isTrue);
      expect(voidWaiting(voided, now0, now0 - 1001), isFalse);
      expect(voidWaiting(voided, now0, now0 - 10 * day), isFalse);
      expect(voidWaiting(voided, now0, now0 + 10 * day), isTrue);
      expect(voidWaiting(voided, now0 + 60000, now0 + 10 * day), isFalse);
      final two = [entry(SpendKind.void_, 1, now0 - 30000, id: spendId('a')), entry(SpendKind.void_, 1, now0 - 1000, id: spendId('b'))];
      expect(voidWaiting(two, now0, now0 - 20000), isTrue);
      expect(voidWaiting(two, now0, now0 - 40000), isFalse);
    });

    test('leaves out of a wait only the entries ahead of the clock, not their count, not their time', () {
      SpendEntry behind(String who, int at) => entry(SpendKind.unanswered, 1, at, id: spendId(who));
      final ahead = behind('z', now0 + day);
      expect(journalWaiting([behind('a', now0 - 30000), ahead], now0), isTrue);
      expect(journalWaiting([behind('a', now0 - 2 * minute), ahead], now0), isFalse);
      expect(journalWaiting([behind('a', now0 - 2 * minute), behind('b', now0 - 3 * hour), ahead], now0), isFalse);
      expect(journalWaiting([behind('a', now0 - 2 * minute + 1), behind('b', now0 - 3 * hour), ahead], now0), isTrue);
    });

    test('has no wait to measure from an entry opened after the guarded clock, and waits from one opened at it', () {
      expect(journalWaiting([entry(SpendKind.unanswered, 1, now0)], now0), isTrue);
      expect(journalWaiting([entry(SpendKind.unanswered, 1, now0 + 1)], now0), isFalse);
      expect(journalWaiting([entry(SpendKind.void_, 1, now0 + 10 * day)], now0), isFalse);
      expect(journalAsks([entry(SpendKind.unanswered, 1, now0 + 1)], now0), isTrue);
    });

    test('has status offer a journal that holds an entry while its wait is not running', () {
      expect(journalAsks(const [], now0), isFalse);
      expect(journalAsks([entry(SpendKind.offline, 1, now0)], now0), isTrue);
      expect(journalAsks(unanswered(1, ago: 30000), now0), isFalse);
      expect(journalAsks(unanswered(1, ago: minute), now0), isTrue);
    });
  });

  group('what a use answer does', () {
    const meters = {'exports': {'left': 89, 'total': 100, 'offline': 10}};

    test("a spent answer is a spend, with the figures stamped by the server's time", () {
      final spent = outcome(HttpResponse(200, {'spent': true, 'meters': meters, 'at': now0 + 1, 'spends': [{'id': spendId('A'), 'n': 2}]}));
      expect(spent.outcome, UseOutcomeKind.spent);
      expect(spent.patch, isEmpty);
      expect(spent.figures, {'exports': const MeterFigure(left: 89, total: 100, offline: 10, resets: false, at: now0 + 1)});
      expect([for (final c in spent.confirmed) c.toJson()], [{'id': spendId('A'), 'n': 2}]);
      expect(outcome(const HttpResponse(200, {'spent': true, 'meters': meters, 'at': 1.5})).figures, isEmpty);
      expect(outcome(const HttpResponse(200, {'spent': 'true', 'meters': meters, 'at': now0})).outcome, UseOutcomeKind.unanswered);
    });

    test('used-up carries what the answer says is left, on any status but a 200, a 5xx and a 429', () {
      UseOutcome usedUp(int status, Object left) => outcome(HttpResponse(status, {'error': 'used-up', 'left': left}));
      expect([usedUp(409, 3).outcome, usedUp(409, 3).left], [UseOutcomeKind.usedUp, 3]);
      expect(usedUp(400, 0).left, 0);
      expect(usedUp(409, -1).left, isNull);
      expect(usedUp(409, 1.5).left, isNull);
      expect(usedUp(503, 3).outcome, UseOutcomeKind.unanswered);
      expect(usedUp(429, 3).outcome, UseOutcomeKind.unanswered);
    });

    test('stores a verdict as a validate does, and a missing answer as the wait of an unanswered request', () {
      final revoked = outcome(HttpResponse(403, {'error': 'revoked', 'spends': [{'id': spendId('A'), 'n': 1}]}));
      expect([revoked.outcome, revoked.refusal], [UseOutcomeKind.refused, Refusal.revoked]);
      expect(revoked.confirmed, hasLength(1));
      expect(revoked.patch, {
        'checkedMajor': 3, 'backoffSince': now0, 'backoffMs': hour, 'deviceKind': 'machine',
        'refused': 'revoked', 'refusedMajor': null, 'refusedFor': null, 'lease': null,
      });
      expect(outcome(null).patch, {'backoffSince': now0, 'backoffMs': 60000, 'deviceKind': 'machine'});
      expect(outcome(const HttpResponse(500, null)).patch, isEmpty);
    });
  });

  group('the reports', () {
    test('are the journal oldest first, a void marked, none for none, and at most 64', () {
      expect(spendsReported(const []), isNull);
      expect(spendsReported([entry(SpendKind.void_, 1, now0), entry(SpendKind.unanswered, 1, now0, id: spendId('B'))]), [
        {'id': spendId('A'), 'meter': 'exports', 'n': 1, 'at': now0, 'void': true},
        {'id': spendId('B'), 'meter': 'exports', 'n': 1, 'at': now0},
      ]);
      final many = [for (var i = 0; i < maxPendingSpends + 3; i++) entry(SpendKind.offline, 1, now0, id: numbered(i))];
      expect(spendsReported(many), hasLength(maxPendingSpends));
    });

    test('are confirmed by an answer that is not a 5xx, a 429 or none, read leniently', () {
      const body = {
        'spends': [
          {'id': 'a', 'n': 2}, {'id': 'b', 'void': true}, {'id': 'c', 'n': 0}, {'n': 1}, 'x', {'id': 'd', 'n': 1.5},
          {'id': 'e', 'void': 'true'}, {'id': 'f', 'n': 9007199254740992.0},
        ]
      };
      List<Map<String, Object?>> read(HttpResponse? r) => [for (final Confirmed c in spendsConfirmed(r)) c.toJson()];
      expect(read(const HttpResponse(200, body)), [{'id': 'a', 'n': 2}, {'id': 'b', 'void': true}]);
      expect(read(const HttpResponse(403, body)), hasLength(2));
      for (final status in [500, 503, 429]) {
        expect(read(HttpResponse(status, body)), isEmpty, reason: '$status');
      }
      expect(read(null), isEmpty);
      expect(read(const HttpResponse(200, {'spends': 'x'})), isEmpty);
    });
  });
}
