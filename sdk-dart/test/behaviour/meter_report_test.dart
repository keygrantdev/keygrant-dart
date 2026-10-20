// The journal of unsynced spends is reported with the next validate, use and
// deactivate, dropped only when the server confirms it, and never costs a
// customer a renewal or a release; status().meters shows each meter of the
// lease, net of the journal (the SDK contract, 12.6 to 12.8; meter-reports.test.ts,
// meters.test.ts, MeterReportTests.swift).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/meters.dart' show maxPendingSpends;

import '../support/files_support.dart';
import '../support/harness.dart';
import '../support/meter_support.dart';

List<SpendEntry> longJournal(int count) =>
    [for (var i = 0; i < count; i++) entry(SpendKind.unanswered, 1, longAgo, id: numbered(i, 'q'), meter: 'm$i')];

Map<String, Object?> reported(SpendEntry e) =>
    {'id': e.id, 'meter': e.meter, 'n': e.n, 'at': e.at, if (e.isVoid) 'void': true};

MeterStatus shown(int left, int total, int offline, int unsynced, bool resets) =>
    MeterStatus(left: left, total: total, offline: offline, unsynced: unsynced, resets: resets);

int? reportedCount(Harness h, [int nth = 0]) => (h.report(nth) as List?)?.length;

void main() {
  group('what a validate reports', () {
    test('carries the journal oldest first, a void marked, and no spends at all when there is none', () async {
      final spends = [
        entry(SpendKind.offline, 3, now0 - 3000, id: spendId('A')),
        entry(SpendKind.unanswered, 1, now0 - 2000, id: spendId('B')),
        entry(SpendKind.void_, 2, now0 - 1000, id: spendId('C')),
      ];
      final h = await holdingJournal(spends);
      await h.renewing();
      await h.license.refresh();
      expect(h.report(0), [for (final e in spends) reported(e)]);
      final bare = await holding();
      await bare.renewing();
      await bare.license.refresh();
      expect(bare.http.bodyOf('validate').containsKey('spends'), isFalse);
    });

    test('reports only what is valid of a stored journal, and renews all the same', () async {
      final h = await holding(state: {
        'spends': [
          {'id': spendId('A'), 'meter': 'exports', 'n': 2, 'at': now0, 'kind': 'offline'},
          {'id': 4}, null, 'x', {'id': spendId('Z'), 'meter': 'exports', 'n': 0, 'at': now0, 'kind': 'offline'},
        ]
      });
      await h.renewing();
      expect((await h.license.refresh()).state, LicenseState.licensed);
      expect(reportedCount(h), 1);
      final junk = await holding(state: {'spends': {'not': 'a list'}});
      await junk.renewing();
      expect((await junk.license.refresh()).state, LicenseState.licensed);
      expect(junk.http.bodyOf('validate').containsKey('spends'), isFalse);
    });

    test('renews with a journal that is full, and reports the first 64 of a longer one', () async {
      final h = await holdingJournal(longJournal(maxPendingSpends));
      await h.renewing();
      expect((await h.license.refresh()).state, LicenseState.licensed);
      expect(reportedCount(h), maxPendingSpends);
      final longer = await holdingJournal(longJournal(70));
      await longer.renewing();
      await longer.license.refresh();
      expect(reportedCount(longer), 64);
    });

    test('drops exactly the entries the answer names as recorded', () async {
      final h = await holdingJournal([
        entry(SpendKind.unanswered, 3, longAgo, id: spendId('A')),
        entry(SpendKind.offline, 5, longAgo, id: spendId('B'), meter: 'renders'),
        entry(SpendKind.void_, 1, longAgo, id: spendId('C')),
        entry(SpendKind.void_, 1, longAgo, id: spendId('D'), meter: 'renders'),
        entry(SpendKind.unanswered, 2, longAgo, id: spendId('F')),
      ]);
      h.http.on('validate', (_) => HttpResponse(200, {
            'lease': 'not a lease',
            'spends': [
              {'id': spendId('A'), 'n': 3}, {'id': spendId('F'), 'n': 7}, {'id': spendId('B'), 'n': 4},
              {'id': spendId('C'), 'void': true}, {'id': spendId('D'), 'n': 1},
              {'id': spendId('E'), 'n': 1}, {'n': 2}, 'x', null,
            ],
          }));
      await h.license.refresh();
      expect([for (final e in h.journal) e.id], [spendId('B'), spendId('D')]);
    });

    test('keeps an offline entry another process grew meanwhile, with its count', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 3, longAgo, id: spendId('A'))]);
      h.http.on('validate', (_) {
        h.stored = StoredState.fromJson({...h.storedJson, 'spends': journalJson([entry(SpendKind.offline, 5, longAgo, id: spendId('A'))])});
        return HttpResponse(200, {'lease': 'no lease', 'spends': [{'id': spendId('A'), 'n': 3}]});
      });
      await h.license.refresh();
      expect(h.journal, [entry(SpendKind.offline, 5, longAgo, id: spendId('A'))]);
    });

    test('drops nothing when the answer names nothing, and waits an hour before status offers it again', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 1, longAgo)]);
      await h.renewing();
      await h.license.refresh();
      expect(h.journal, hasLength(1));
      expect(h.stored?.backoffMs, hour);
      await h.license.status();
      expect(h.http.count('validate'), 1);
      h.clock.value = now0 + hour;
      await h.license.status();
      expect(h.http.count('validate'), 2);
    });

    test('drops nothing on a 5xx or a 429 whatever their body says, nor on no answer', () async {
      for (final status in [503, 429, 0]) {
        final h = await holdingJournal([entry(SpendKind.unanswered, 3, longAgo, id: spendId('A'))]);
        if (status == 0) {
          h.http.fail = true;
        } else {
          h.http.on('validate', (_) => HttpResponse(status, {'spends': [{'id': spendId('A'), 'n': 3}]}));
        }
        await h.license.refresh();
        expect(h.http.count('validate'), 1, reason: '$status');
        expect(h.journal, hasLength(1), reason: '$status');
      }
    });

    test('drops what a refusal confirms, and what an answer with no lease confirms', () async {
      final held = [entry(SpendKind.unanswered, 3, longAgo, id: spendId('A'))];
      final h = await holdingJournal(held);
      h.http.on('validate', (_) => HttpResponse(403, {'error': 'revoked', 'spends': [{'id': spendId('A'), 'n': 3}]}));
      final status = await h.license.refresh();
      expect([status.state, status.reason], [LicenseState.invalid, LicenseReason.revoked]);
      expect(h.journal, isEmpty);
      final g = await holdingJournal(held);
      g.http.on('validate', (_) => HttpResponse(200, {'spends': [{'id': spendId('A'), 'n': 3}]}));
      await g.license.refresh();
      expect(g.journal, isEmpty);
    });

    test('keeps the confirmation in memory when it cannot be saved, so the entry is not reported again', () async {
      final h = await holdingJournal([entry(SpendKind.unanswered, 3, longAgo, id: spendId('A'))]);
      final lease = await meteredLease(h);
      h.http.on('validate', (_) => HttpResponse(200, {'lease': lease, 'spends': [{'id': spendId('A'), 'n': 3}]}));
      h.storage.failWrites = true;
      await h.license.refresh();
      expect(h.journal, hasLength(1));
      expect((await h.license.status()).meters['exports']?.unsynced, 0);
      await h.license.refresh();
      expect(h.http.count('validate'), 2);
      expect(h.report(1), isNull);
      h.storage.failWrites = false;
      await h.license.status();
      expect(h.journal, isEmpty);
    });

    test("reports to a valid lease at the next status once its own wait is not running, and not before", () async {
      final h = await holdingJournal([entry(SpendKind.unanswered, 1, now0 - 30000, id: spendId('A'))]);
      final lease = await meteredLease(h);
      h.http.on('validate', (_) => HttpResponse(200, {'lease': lease, 'spends': [{'id': spendId('A'), 'n': 1}]}));
      await h.license.status();
      expect(h.http.count('validate'), 0);
      h.clock.value = now0 - 30000 + minute;
      await h.license.status();
      expect(h.http.count('validate'), 1);
      expect(h.journal, isEmpty);
      await h.license.status();
      expect(h.http.count('validate'), 1);
    });

    test("reports an offline-only journal at once, and waits for the ask's own wait after no answer", () async {
      final h = await holdingJournal([entry(SpendKind.offline, 2, now0)]);
      h.http.fail = true;
      await h.license.status();
      expect(h.http.count('validate'), 1);
      expect(h.stored?.backoffMs, 60000);
      await h.license.status();
      expect(h.http.count('validate'), 1);
      h.http.fail = false;
      final lease = await meteredLease(h);
      h.http.on('validate', (_) => HttpResponse(200, {'lease': lease, 'spends': [{'id': spendId('A'), 'n': 2}]}));
      h.clock.value = now0 + minute;
      await h.license.status();
      expect(h.journal, isEmpty);
    });

    test('asks of a lease past its end to heal it, with the journal', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 1, now0 - 40 * day)]);
      h.clock.value = now0 + 40 * day;
      h.http.on('validate', (_) => const HttpResponse(200, {}));
      await h.license.status();
      expect(reportedCount(h), 1);
    });

    test('rides a use request too, and is dropped by what that request confirms', () async {
      final held = entry(SpendKind.unanswered, 2, longAgo, id: spendId('A'));
      final h = await holdingJournal([held]);
      h.http.on('use', (_) => HttpResponse(200, {
            'spent': true, 'at': now0, 'meters': {'exports': {'left': 87, 'total': 100, 'offline': 10}},
            'spends': [{'id': spendId('A'), 'n': 2}],
          }));
      expect(await h.license.use('exports'), spentLeft(87));
      expect(h.useBody()['spends'], [reported(held)]);
      expect(h.journal, isEmpty);
    });

    test('an entry the server did not confirm is reported again with the same id, meter, count and time', () async {
      for (final name in ['nothing named', '503', '429', 'no answer', 'a lower count']) {
        final held = entry(SpendKind.offline, 3, longAgo, id: spendId('A'));
        final h = await holdingJournal([held]);
        final lease = await meteredLease(h);
        switch (name) {
          case 'nothing named':
            h.renews(lease);
          case '503' || '429':
            h.http.on('validate', (_) => HttpResponse(int.parse(name), {'error': 'down'}));
          case 'no answer':
            h.http.fail = true;
          default:
            h.http.on('validate', (_) => HttpResponse(200, {'lease': lease, 'spends': [{'id': spendId('A'), 'n': 2}]}));
        }
        await h.license.refresh();
        expect(h.journal, [held], reason: name);
        h.http.fail = false;
        h.clock.value = now0 + 2 * hour;
        h.renews(lease);
        await h.license.refresh();
        expect(h.report(h.http.count('validate') - 1), [reported(held)], reason: name);
        h.http.on('use', (_) => spent(89));
        await h.license.use('exports');
        expect(h.useBody()['spends'], [reported(held)], reason: name);
      }
    });

    test("carries the id a failed use sent into the next request's report", () async {
      final h = await holding();
      h.http.fail = true;
      await h.license.use('exports', 2);
      final sent = h.useBody()['id'];
      h.http.fail = false;
      h.clock.value = now0 + 2 * minute;
      await h.renewing();
      await h.license.refresh();
      expect(h.report(0), [{'id': sent, 'meter': 'exports', 'n': 2, 'at': now0}]);
      h.http.on('use', (_) => spent(89));
      await h.license.use('exports');
      expect(((h.useBody(1)['spends'] as List).first as Map)['id'], sent);
    });

    test('sends no spends with an activation or a trial, though the journal holds some', () async {
      final h = await holdingJournal([entry(SpendKind.offline, 1, longAgo)]);
      h.activates(await meteredLease(h));
      expect((await h.license.activate(key1)).ok, isTrue);
      await h.license.startTrial();
      expect(h.http.count('trial'), 1);
      expect(h.http.bodyOf('activate').containsKey('spends'), isFalse);
      expect(h.http.bodyOf('trial').containsKey('spends'), isFalse);
    });

    test('a full journal refuses a spend the allowance covers, though the request was sent, and appends no void', () async {
      final h = await holdingJournal(longJournal(maxPendingSpends));
      h.http.fail = true;
      expect(await h.license.use('exports'), useRefused(UseError.offlineLimit, 90));
      expect(h.http.count('use'), 1);
      expect(h.journal, hasLength(maxPendingSpends));
      expect(h.journal.any((e) => e.isVoid), isFalse);
    });
  });

  group('status().meters', () {
    test('shows each meter of the lease with its figures, and nothing when the lease has none', () async {
      final h = await holding();
      final status = await h.license.status();
      expect([status.state, status.key], [LicenseState.licensed, key1]);
      expect(status.meters, {'exports': shown(90, 100, 10, 0, false), 'renders': shown(5, 5, 0, 0, true)});
      expect(h.http.count('validate'), 0);
      final bare = await holding(met: null);
      expect(await bare.license.status(), keyLicensed);
    });

    test('is net of the unsynced spends of each kind, never below 0, and counts no void', () async {
      final h = await holding(state: {
        'spends': journalJson([
          entry(SpendKind.offline, 4, now0), entry(SpendKind.unanswered, 3, now0, id: spendId('B')),
          entry(SpendKind.void_, 50, now0, id: spendId('C')), entry(SpendKind.offline, 9, now0, id: spendId('D'), meter: 'renders'),
        ]),
        ...waitRunning,
      });
      final meters = (await h.license.status()).meters;
      expect(meters['exports'], shown(83, 100, 10, 7, false));
      expect(meters['renders'], shown(0, 5, 0, 9, true));
    });

    test('is absent on every status but a key licensed one: expired, refused, none, a trial and a file', () async {
      final expired = await holding();
      expired.clock.value = now0 + 40 * day;
      expired.http.fail = true;
      final status = await expired.license.status();
      expect([status.state, status.meters], [LicenseState.expired, isEmpty]);
      expect((await (await holding(state: {'refused': 'revoked'})).license.status()).meters, isEmpty);
      expect((await (await Harness.create()).license.status()).meters, isEmpty);
      final trial = await Harness.create();
      final lease = await trial.signer.lease('trial:fp-test', model: 'trial', ttlSeconds: 5 * 86400, extra: {'met': usualMeters});
      trial.http.on('trial', (_) => HttpResponse(200, {'trialStart': now0, 'trialEndsAt': now0 + 5 * day, 'lease': lease}));
      final started = await trial.license.startTrial();
      expect([started.state, started.meters], [LicenseState.trial, isEmpty]);
      final file = await holding();
      await file.license.importLicenseFile(fileText(await offlineFile(file, {'met': usualMeters})));
      expect(await file.license.status(), fileLicensed);
      expect(await file.license.use('exports'), useRefused(UseError.notLicensed));
    });

    test('keeps a copy of its own in each status, which the app cannot change', () async {
      final h = await holding();
      final a = await h.license.status();
      final b = await h.license.status();
      expect(identical(a.meters, b.meters), isFalse);
      expect(() => a.meters['exports'] = shown(1, 1, 1, 1, false), throwsUnsupportedError);
    });

    test("shows a meter named __proto__ or like an object's member as a meter like any other", () async {
      final h = await holding(met: {
        '__proto__': {'left': 1, 'total': 2, 'offline': 0},
        'constructor': {'left': 3, 'total': 3, 'offline': 1},
      });
      final meters = (await h.license.status()).meters;
      expect(meters.keys.toList()..sort(), ['__proto__', 'constructor']);
      expect(meters['__proto__'], shown(1, 2, 0, 0, false));
    });

    test("takes a figure a use answer gave in place of the lease's, from the lease's own second on", () async {
      Future<int?> leftWith(int at) async => (await (await holding(state: {
            'meterFigures': {'exports': MeterFigure(left: 40, total: 100, offline: 10, resets: false, at: at).toJson()}
          }))
                  .license
                  .status())
          .meters['exports']
          ?.left;
      expect(await leftWith(now0 + 1000), 40);
      expect(await leftWith(now0 - 1000), 90);
      expect(await leftWith(now0), 40);
    });

    test("shows a renewal's meters net of the journal after what the answer confirmed", () async {
      final h = await holdingJournal([entry(SpendKind.offline, 2, longAgo, id: spendId('A')), entry(SpendKind.void_, 1, longAgo, id: spendId('B'))]);
      final lease = await meteredLease(h, met: {'exports': {'left': 70, 'total': 100, 'offline': 10}}, at: now0 + 5000);
      h.http.on('validate', (_) => HttpResponse(200, {'lease': lease, 'spends': [{'id': spendId('A'), 'n': 2}]}));
      h.clock.value = now0 + 5000;
      expect((await h.license.refresh()).meters, {'exports': shown(70, 100, 10, 0, false)});
    });

    test('stops showing a meter the newest lease no longer names, and spends on an open-ended lease', () async {
      final h = await holding(
          met: {'exports': {'left': 70, 'total': 100, 'offline': 10}},
          state: {'meterFigures': {'renders': const MeterFigure(left: 1, total: 5, offline: 0, resets: true, at: now0 - 5000).toJson()}});
      expect((await h.license.status()).meters.keys, ['exports']);
      final open = await Harness.create();
      open.hold(await meteredLease(open, over: {'model': 'perpetual', 'major': 1000000}), {'lastSeen': now0});
      open.http.on('use', (_) => spent(89));
      expect(await open.license.use('exports'), spentLeft(89));
    });
  });
}
