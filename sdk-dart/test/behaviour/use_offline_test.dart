// use(meter, n) when nothing answers: the allowance, the journal and its
// waits, what is stored of a spend, and the state a licence leaves behind (the
// SDK contract, 12.4 and 12.5; use.test.ts, UseOfflineTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/meters.dart' show maxMeterUses, maxPendingSpends, pendingMaxMs;

import '../support/harness.dart';
import '../support/meter_support.dart';

Matcher offlineLimit(int left) => useRefused(UseError.offlineLimit, left);

/// A key whose exports have the allowance `offline`.
Future<Harness> limited(int offline) => holding(met: {'exports': {'left': 90, 'total': 100, 'offline': offline}});

List<SpendEntry> fullJournal() => [
      for (var i = 0; i < maxPendingSpends; i++) entry(SpendKind.unanswered, 1, now0 - 1, id: numbered(i, 'x'), meter: 'm$i')
    ];

void main() {
  group('with no answer', () {
    test('spends from the allowance, journals the spend under the id it sent, and waits a minute', () async {
      final h = await holding();
      h.http.fail = true;
      expect(await h.license.use('exports'), spentLeft(89, offline: true));
      final sent = h.useBody()['id'] as String;
      expect(h.journal, [SpendEntry(id: sent, meter: 'exports', n: 1, at: now0, kind: SpendKind.unanswered)]);
      expect([h.stored?.backoffSince, h.stored?.backoffMs], [now0, 60000]);
      expect(await h.license.use('exports', 2), spentLeft(87, offline: true));
      expect(h.http.count('use'), 1);
      expect(kindsAndCounts(h.journal), ['unanswered 1', 'offline 2']);
      expect(await h.license.use('exports'), spentLeft(86, offline: true));
      expect(kindsAndCounts(h.journal), ['unanswered 1', 'offline 3']);
    });

    test('refuses a spend past the allowance, and past what is left', () async {
      final h = await limited(3);
      h.http.fail = true;
      expect(await h.license.use('exports', 2), spentLeft(88, offline: true));
      expect(await h.license.use('exports', 2), offlineLimit(88));
      expect(await h.license.use('exports'), spentLeft(87, offline: true));
      expect(await h.license.use('exports'), offlineLimit(87));
      final low = await holding(met: {'exports': {'left': 2, 'total': 100, 'offline': 50}});
      low.http.fail = true;
      expect(await low.license.use('exports', 3), offlineLimit(2));
      expect(await low.license.use('exports', 2), spentLeft(0, offline: true));
      expect(await low.license.use('exports'), offlineLimit(0));
    });

    test('answers, whatever it answers, with a clock far past the lease', () async {
      final h = await holding();
      h.http.fail = true;
      h.clock.value = 1 << 53;
      expect((await h.license.use('exports')).ok, isFalse);
      await h.license.status();
    });

    test('refuses every spend with no answer on a meter whose allowance is 0, and spends it online', () async {
      final h = await holding();
      h.http.fail = true;
      expect(await h.license.use('renders'), offlineLimit(5));
      h.http.fail = false;
      h.clock.value = now0 + 2 * minute;
      h.http.on('use', (_) => rendersSpent(at: now0 + 2 * minute));
      expect(await h.license.use('renders'), spentLeft(4));
    });

    test('journals a refusal of a spend that was sent as a void, for the server to take back', () async {
      final h = await limited(1);
      h.http.fail = true;
      await h.license.use('exports');
      h.clock.value = now0 + 2 * minute;
      expect(await h.license.use('exports'), offlineLimit(89));
      expect(kindsAndCounts(h.journal), ['unanswered 1', 'void 1']);
      expect(h.journal[1], SpendEntry(id: h.useBody(1)['id'] as String, meter: 'exports', n: 1, at: now0 + 2 * minute, kind: SpendKind.void_));
    });

    test('asks again for a spend the allowance refuses, though the minute has not passed', () async {
      final h = await limited(1);
      h.http.fail = true;
      await h.license.use('exports');
      expect(await h.license.use('exports'), offlineLimit(89));
      expect(h.http.count('use'), 2);
      expect([for (final e in h.journal) e.kind], [SpendKind.unanswered, SpendKind.void_]);
    });

    test('serves a customer who is back online at once, though the last outage left a wait', () async {
      final h = await holding();
      h.http.fail = true;
      expect(await h.license.use('exports'), spentLeft(89, offline: true));
      h.http.fail = false;
      h.http.on('use', (_) => rendersSpent());
      expect(await h.license.use('renders'), spentLeft(4));
      h.http.on('use', (_) => spent(70));
      expect(await h.license.use('exports', 50), spentLeft(69));
      h.http.on('use', (_) => const HttpResponse(200, {'spent': true, 'at': now0, 'meters': {'credits': {'left': 9, 'total': 10, 'offline': 0}}}));
      expect(await h.license.use('credits'), spentLeft(9));
      final asked = h.http.count('use');
      expect((await h.license.use('exports') as UseSpent).offline, isTrue);
      expect(h.http.count('use'), asked);
    });

    test('counts a 5xx and a 429 as no answer, saves nothing of them, and journals the spend in doubt', () async {
      for (final (status, body) in [(500, {'error': 'boom'}), (503, null), (429, {'error': 'rate-limited'})]) {
        final h = await holding();
        h.http.on('use', (_) => HttpResponse(status, body));
        expect(await h.license.use('exports'), spentLeft(89, offline: true), reason: '$status');
        expect(kindsAndCounts(h.journal), ['unanswered 1'], reason: '$status');
        expect(h.stored?.backoffSince, isNull, reason: '$status');
      }
    });

    test('counts any answer it cannot use as no answer too, and saves nothing of it', () async {
      final answers = <(int, Object?)>[
        (200, {'spent': false}), (200, 'ok'), (200, null), (400, {'error': 'invalid-request'}),
        (404, {'error': 'invalid-key'}), (403, {'error': 'something-new'}), (401, 'denied'),
      ];
      for (final (status, body) in answers) {
        final h = await holding();
        h.http.on('use', (_) => HttpResponse(status, body));
        expect(await h.license.use('exports'), spentLeft(89, offline: true), reason: '$status $body');
        expect(h.journal.single.kind, SpendKind.unanswered, reason: '$status $body');
        expect([h.stored?.backoffSince, h.stored?.refused], [null, null], reason: '$status $body');
      }
    });

    test('does not take the confirmations of an answer it cannot use', () async {
      final h = await holdingJournal([entry(SpendKind.unanswered, 1, now0, id: spendId('E'))]);
      h.http.on('use', (_) => HttpResponse(500, {'spends': [{'id': spendId('E'), 'n': 1}]}));
      h.clock.value = now0 + 2 * minute;
      await h.license.use('exports');
      expect(h.http.count('use'), 1);
      expect(h.journal.any((e) => e.id == spendId('E')), isTrue);
    });

    test("asks again once the minute is over, the journal's wait doubling to an hour", () async {
      final h = await holding(met: {'exports': {'left': 1000000, 'total': 1000000, 'offline': 1000000}});
      h.http.fail = true;
      var at = now0;
      final waits = [1, 2, 4, 8, 16, 32, 60, 60];
      for (var i = 0; i < waits.length; i++) {
        h.clock.value = at;
        await h.license.use('exports');
        expect(h.http.count('use'), i + 1, reason: 'ask ${i + 1}');
        h.clock.value = at + waits[i] * minute - 1;
        await h.license.use('exports');
        expect(h.http.count('use'), i + 1, reason: 'short of wait ${i + 1}');
        at += waits[i] * minute;
      }
    });

    test("keeps the journal's wait when the device clock is set back", () async {
      final h = await holding();
      h.http.fail = true;
      h.clock.value = now0 + 10 * minute;
      await h.license.use('exports');
      h.clock.value = now0;
      await h.license.use('exports');
      expect(h.http.count('use'), 1);
    });

    test('asks at once when a stored no-answer wait begins after the device clock', () async {
      final h = await holding(state: {'backoffSince': now0 + 10 * minute, 'backoffMs': 60000});
      h.http.on('use', (_) => spent(89));
      expect(await h.license.use('exports'), spentLeft(89));
    });

    test('asks when the newest unanswered spend was opened after the guarded clock', () async {
      final ahead = await holdingJournal([entry(SpendKind.unanswered, 1, now0 + 5 * day)]);
      ahead.http.on('use', (_) => spent(89));
      expect(await ahead.license.use('exports'), spentLeft(88));
      expect(ahead.http.count('use'), 1);
      final at = await holdingJournal([entry(SpendKind.unanswered, 1, now0)]);
      at.http.on('use', (_) => spent(89));
      await at.license.use('exports');
      expect(at.http.count('use'), 0);
    });

    test('does not wait on the longer wait a validate set: the use endpoint is asked all the same', () async {
      final h = await holding(state: {'backoffSince': now0, 'backoffMs': hour});
      h.http.on('use', (_) => spent(89));
      expect(await h.license.use('exports'), spentLeft(89));
    });

    test('refuses a meter the key has no figure for as no-meter, and journals a void when in doubt', () async {
      final h = await holding();
      h.http.fail = true;
      expect(await h.license.use('credits'), useRefused(UseError.noMeter));
      expect(kindsAndCounts(h.journal), ['void 1']);
      expect(h.journal.single.meter, 'credits');
      final waiting = await holding(state: waitRunning);
      waiting.http.fail = true;
      expect(await waiting.license.use('credits'), useRefused(UseError.noMeter));
      expect(waiting.http.count('use'), 1);
      expect(waiting.journal.single.kind, SpendKind.void_);
    });

    test('fills the journal to 64 and refuses the 65th spend as past the allowance', () async {
      final h = await holding(state: {'spends': journalJson(fullJournal()), ...waitRunning});
      expect(await h.license.use('exports'), offlineLimit(90));
      expect(h.journal, hasLength(maxPendingSpends));
    });

    test('lets an offline entry that is already open grow when the journal is full', () async {
      final full = [entry(SpendKind.offline, 2, now0, id: 'x' * 22), ...fullJournal().take(maxPendingSpends - 1)];
      final h = await holding(state: {'spends': journalJson(full), ...waitRunning});
      expect(await h.license.use('exports'), spentLeft(87, offline: true));
      expect(h.journal, hasLength(maxPendingSpends));
      expect(h.journal.first.n, 3);
    });

    test('waits the hour after a journal of 64 unanswered entries', () async {
      const opened = now0 - 10 * minute;
      final spends = [for (var i = 0; i < 64; i++) entry(SpendKind.unanswered, 1, opened + i, id: numbered(i, 'u'), meter: 'credits')];
      final h = await holding(state: {'spends': journalJson(spends)});
      h.http.fail = true;
      h.clock.value = opened + 63 + hour - 1;
      await h.license.use('exports');
      expect(h.http.count('use'), 0, reason: 'an hour has not passed');
      h.clock.value = opened + 63 + hour;
      await h.license.use('exports');
      expect(h.http.count('use'), 1, reason: 'an hour has passed');
    });
  });

  group('the journal', () {
    test('survives a save that fails: it counts toward the allowance and the status, and lands with the next save', () async {
      final h = await limited(2);
      h.http.fail = true;
      h.storage.failWrites = true;
      expect(await h.license.use('exports'), spentLeft(89, offline: true));
      expect(await h.license.use('exports'), spentLeft(88, offline: true));
      expect(h.journal, isEmpty);
      expect(await h.license.use('exports'), offlineLimit(88));
      expect((await h.license.status()).meters['exports'], const MeterStatus(left: 88, total: 100, offline: 2, unsynced: 2, resets: false));
      h.storage.failWrites = false;
      await h.license.status();
      expect(h.journal.where((e) => !e.isVoid).fold(0, (a, e) => a + e.n), 2);
      expect(h.journal.where((e) => e.isVoid), hasLength(1));
      h.storage.failWrites = true;
      expect((await h.license.status()).meters['exports']?.unsynced, 2);
    });

    test('lands with the next use that can save, in order', () async {
      final h = await holding();
      h.http.fail = true;
      h.storage.failWrites = true;
      await h.license.use('exports');
      h.storage.failWrites = false;
      h.http.fail = false;
      h.http.on('use', (body) => HttpResponse(200, {
            'spent': true, 'at': now0,
            'meters': {'exports': {'left': 88, 'total': 100, 'offline': 10}},
            'spends': [for (final s in (body['spends'] as List? ?? const [])) {'id': (s as Map)['id'], 'n': s['n']}],
          }));
      h.clock.value = now0 + 2 * minute;
      expect(await h.license.use('exports'), spentLeft(88));
      expect(h.useBody(1)['spends'], hasLength(1));
      expect(h.journal, isEmpty);
    });

    test("lands on the state as stored now, so a second process's spend is never lost", () async {
      final h = await limited(10);
      h.http.fail = true;
      final app = h.appOver(Racing(h, [entry(SpendKind.offline, 4, now0 - 5, id: spendId('O'))]));
      expect((await app.use('exports')).ok, isTrue);
      expect((await app.use('exports', 2)).ok, isTrue);
      expect([for (final e in h.journal) '${e.id == spendId('O') ? 'theirs' : e.kind.wire} ${e.n}'], ['theirs 6', 'unanswered 1']);
    });

    test('lands on the state as it is at the save when the storage has no merge of its own', () async {
      final h = await limited(10);
      h.http.on('use', (_) {
        h.stored = StoredState.fromJson({
          ...h.storedJson,
          'spends': journalJson([entry(SpendKind.offline, 4, now0 - 5, id: spendId('O'))]),
        });
        return const HttpResponse(503, {});
      });
      expect((await h.license.use('exports')).ok, isTrue);
      expect(kindsAndCounts(h.journal), ['offline 4', 'unanswered 1']);
      expect(h.journal.first.id, spendId('O'));
    });

    test('keeps an entry with the seat it is about, and nothing of it on another seat', () async {
      final figures = {'exports': const MeterFigure(left: 50, total: 100, offline: 10, resets: false, at: now0).toJson()};
      final h = await holding(state: {'spends': journalJson([entry(SpendKind.offline, 2, now0)]), 'meterFigures': figures});
      h.activates(await meteredLease(h));
      expect((await h.license.activate(key1)).ok, isTrue);
      expect(h.journal, hasLength(1));
      expect(h.stored?.meterFigures, isNotEmpty);
      h.activates(await meteredLease(h, over: {'aid': 'act_9'}), activationId: 'act_9');
      expect((await h.license.activate(key1)).ok, isTrue);
      expect([h.stored?.activationId, h.storedJson['spends'], h.storedJson['meterFigures']], ['act_9', null, null]);
    });

    test('drops the journal of an old activation when another key is activated, unreported', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 2, now0)]);
      const another = 'SLUICE-OTHER-AAAA-BBBB-CCCC';
      final lease = await h.signer.lease(another, model: 'subscription', major: 3, aid: 'act_2', extra: {'met': usualMeters});
      h.activates(lease, activationId: 'act_2');
      expect((await h.license.activate(another)).ok, isTrue);
      expect(h.http.count('validate'), 0);
      expect([h.stored?.key, h.storedJson['spends']], [another, null]);
    });

    test('drops entries unreported for more than 180 days at the next save, and keeps one exactly that old', () async {
      final h = await holdingJournal([
        entry(SpendKind.unanswered, 1, now0 - 181 * day, id: 'o' * 22),
        entry(SpendKind.unanswered, 1, now0 - pendingMaxMs, id: 'b' * 22),
      ]);
      h.http.fail = true;
      await h.license.use('exports');
      final ids = [for (final e in h.journal) e.id];
      expect(ids, isNot(contains('o' * 22)));
      expect(ids, contains('b' * 22));
      h.clock.value = now0 + 1;
      await h.license.use('exports');
      expect([for (final e in h.journal) e.id], isNot(contains('b' * 22)));
      expect(pendingMaxMs, 180 * day);
    });

    test('reads a stored journal that is not one as empty, and an entry of another shape as none', () async {
      final h = await Harness.create();
      h.stored = StoredState.fromJson({'key': key1, 'activationId': 'act_1', 'lastSeen': now0, 'lease': await meteredLease(h), 'spends': 'junk'});
      h.http.fail = true;
      expect(await h.license.use('exports'), spentLeft(89, offline: true));
      final g = await Harness.create();
      g.stored = StoredState.fromJson({
        'key': key1, 'activationId': 'act_1', 'lastSeen': now0, 'lease': await meteredLease(g),
        'spends': [
          {'id': 3}, null, 'x',
          {'id': spendId('A'), 'meter': 'exports', 'n': 2, 'at': now0, 'kind': 'offline', 'extra': true},
          {'id': 'x', 'meter': 'exports', 'n': 0, 'at': 1, 'kind': 'offline'},
          {'id': 'y', 'meter': 'exports', 'n': 1.5, 'at': 1, 'kind': 'offline'},
          {'id': 'z', 'meter': 'exports', 'n': 1, 'at': -1, 'kind': 'offline'},
          {'id': 'w', 'meter': 'exports', 'n': 1, 'at': 1, 'kind': 'later'},
        ],
      });
      g.http.fail = true;
      expect((await g.license.status()).meters['exports']?.unsynced, 2);
      expect(await g.license.use('exports'), spentLeft(87, offline: true));
      expect(kindsAndCounts(g.journal), ['offline 3']);
      expect(((g.storedJson['spends'] as List).first as Map).containsKey('extra'), isFalse);
    });

    test('reads stored figures of another shape as none, the lease standing for that meter', () async {
      final h = await holding(state: {
        'meterFigures': {
          'exports': {'left': 1, 'total': 100, 'offline': 10, 'at': now0 + 1, 'extra': 1},
          'renders': {'left': -1, 'total': 5, 'offline': 0, 'at': now0 + 1},
          'credits': 7,
        }
      });
      final shown = (await h.license.status()).meters;
      expect([shown['exports']?.left, shown['renders']?.left, shown['credits']], [1, 5, null]);
    });
  });

  test('keys the install by the machine id it read when the request gets no answer', () async {
    final h = await holding(fingerprinter: ScriptedFingerprinter(const DeviceIdentity(fingerprint: 'fp-machine', kind: DeviceKind.machine)));
    h.http.fail = true;
    await h.license.use('exports');
    expect(h.stored?.deviceKind, DeviceKind.machine);
  });

  test('a licence stays licensed when a meter is used up, absent or past its offline limit', () async {
    final h = await limited(1);
    h.http.fail = true;
    expect((await h.license.use('exports')).ok, isTrue);
    expect(await h.license.use('exports'), offlineLimit(89));
    expect(await h.license.use('credits'), useRefused(UseError.noMeter));
    h.http.fail = false;
    h.http.on('use', (_) => const HttpResponse(409, {'error': 'used-up', 'left': 0}));
    h.clock.value = now0 + hour;
    expect(await h.license.use('exports'), useRefused(UseError.usedUp, 0));
    expect((await h.license.status()).state, LicenseState.licensed);
    expect(await h.license.use('exports', maxMeterUses + 1), useRefused(UseError.invalidAmount));
  });
}
