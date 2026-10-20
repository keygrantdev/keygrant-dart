// Two instances of the app (two processes) on one state file, each with its
// own KeyGrantLicense (storage.test.ts, answers saved by two instances; merge.ts
// `merged`): an older answer never overwrites a newer one, the trial start
// only moves earlier, and the kept major only up.

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/lease.dart' show openMajor;

import '../support/harness.dart';
import '../support/trials_support.dart';

const _revoked = HttpResponse(403, {'error': 'revoked'});
const _keyB = 'SLUICE-BBBB-BBBB-BBBB-BBBB';

HttpResponse _lease(String lease, [String aid = 'act_1']) => HttpResponse(200, {'lease': lease, 'activationId': aid});

const _revokedStatus = LicenseStatus(LicenseState.invalid, reason: LicenseReason.revoked, key: key1);

/// A file holding `key1` on a lease signed a day ago.
Future<MemoryFs> heldFile(Signer s, [Map<String, Object?> lease = const {}]) async => oneFile({
      'key': key1,
      'activationId': 'act_1',
      'lease': await s.lease(key1, at: now0 - day, major: (lease['major'] as int?) ?? 1, extra: lease),
      'checkedMajor': 1,
      'lastSeen': now0 - day,
      'rev': 1,
    });

void main() {
  test("keeps the newer answer: a refusal asked for later survives the re-merge of an older ask's lease", () async {
    final s = await Signer.create();
    final fs = await heldFile(s);
    final a = instanceOver(fs, s, now: now0, answers: {'validate': _lease(await s.lease(key1))});
    final b = instanceOver(fs, s, now: now0 + 1000, answers: {'validate': _revoked});
    final answered = await interleave(fs, a.refresh, () async {
      expect(await b.refresh(), _revokedStatus);
    });
    expect(answered, licensedStatus());
    expect(savedIn(fs)['refused'], 'revoked');
    expect(savedIn(fs)['verdictAt'], now0 + 1000);
    expect(savedIn(fs).containsKey('lease'), isFalse);
    expect(fs.ops.where((op) => op.startsWith('create')), hasLength(3));
  });

  test("keeps the later ask's answer when the clock was put back between the two asks", () async {
    final s = await Signer.create();
    final fs = await heldFile(s);
    final a = instanceOver(fs, s, now: now0, answers: {'validate': _lease(await s.lease(key1))});
    final b = instanceOver(fs, s, now: now0 - 60000, answers: {'validate': _revoked});
    await interleave(fs, a.refresh, () async {
      // A save made at now0 + 2 s, before the clock went back, raised the guard.
      final raised = {...savedIn(fs), 'lastSeen': now0 + 2000, 'rev': (savedIn(fs)['rev'] as int) + 1};
      fs.files[statePath] = oneFile(raised).files[statePath]!;
      await b.refresh();
    });
    expect(savedIn(fs)['refused'], 'revoked');
    expect(savedIn(fs)['verdictAt'], now0 + 2000);
    expect(savedIn(fs).containsKey('lease'), isFalse);
  });

  test('keeps a refusal asked for later over a re-activation of the same seat that saves after it', () async {
    final s = await Signer.create();
    final fs = await heldFile(s);
    final w1 = instanceOver(fs, s, now: now0, answers: {'activate': _lease(await s.lease(key1))});
    final w2 = instanceOver(fs, s, now: now0 + 1000, answers: {'validate': _revoked});
    final activated = await interleave(fs, () => w1.activate(key1), () async {
      expect(await w2.refresh(), _revokedStatus);
    });
    expect(activated, isA<Activated>());
    final saved = savedIn(fs);
    expect(saved['key'], key1);
    expect(saved['activationId'], 'act_1');
    expect(saved['refused'], 'revoked');
    expect(saved['verdictAt'], now0 + 1000);
    expect(saved.containsKey('lease'), isFalse);
    // So the revoked device does not license offline.
    expect((await w1.status()).reason, LicenseReason.revoked);
  });

  group('a renewal that lands after the activation it renewed is gone writes nothing of it', () {
    final window = (now0 + 10 * day) ~/ 1000;
    const machine = IdentityFingerprinter(DeviceIdentity(fingerprint: 'fp-machine', kind: DeviceKind.machine));

    for (final action in ['deactivate', 'activate']) {
      test('no kept major and no install memory: W1 ${action}d', () async {
        final s = await Signer.create();
        final open = {'major': openMajor, 'upgradeUntil': window};
        final fs = await heldFile(s, open);
        final leaseB = await s.lease(_keyB, aid: 'act_2');
        final w1 = instanceOver(fs, s, now: now0, answers: {
          'deactivate': const HttpResponse(200, {'ok': true}),
          'activate': _lease(leaseB, 'act_2'),
        });
        final renewed = await s.lease(key1, major: openMajor, extra: {'upgradeUntil': window});
        final w2 = instanceOver(fs, s, now: now0, answers: {'validate': _lease(renewed)}, fingerprinter: machine);
        await interleave(fs, w2.refresh, () async {
          if (action == 'deactivate') {
            await w1.deactivate();
          } else {
            expect(await w1.activate(_keyB), isA<Activated>());
          }
        });
        final saved = savedIn(fs);
        expect(saved.containsKey('keptMajor'), isFalse);
        expect(saved.containsKey('deviceKind'), isFalse);
        if (action == 'deactivate') {
          expect(saved.containsKey('key'), isFalse);
        } else {
          expect(saved['key'], _keyB);
          expect(saved['activationId'], 'act_2');
          expect(saved['lease'], leaseB);
        }
      });
    }
  });

  test('moves the trial start only earlier, whichever instance saves last', () async {
    final s = await Signer.create();
    final fs = oneFile({'lastSeen': now0, 'rev': 1});
    final a = instanceOver(fs, s, now: now0, answers: {
      'trial': HttpResponse(200, {'trialStart': now0 - 2 * day, 'trialEndsAt': now0 + 5 * day, 'lease': await trialLeaseOf(s)}),
    });
    final bLease = await trialLeaseOf(s, days: 3);
    final b = instanceOver(fs, s, now: now0 + 1000, answers: {
      'trial': HttpResponse(200, {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 + 3 * day, 'lease': bLease}),
    });
    await interleave(fs, a.startTrial, () async {
      expect((await b.startTrial()).trialDaysLeft, 3);
    });
    final saved = savedIn(fs);
    expect(saved['trialStart'], now0 - 9 * day);
    // B asked later: its end and lease are the newer answer, kept over A's.
    expect(saved['trialEndsAt'], now0 + 3 * day);
    expect(saved['trialLease'], bLease);
    expect(saved['trialAt'], now0 + 1000);
  });

  test('keeps the earlier start of an older trial answer that saves after a newer one', () async {
    final s = await Signer.create();
    final fs = oneFile({'lastSeen': now0, 'rev': 1});
    final a = instanceOver(fs, s, now: now0, answers: {
      'trial': HttpResponse(200, {'trialStart': now0 - 9 * day, 'trialEndsAt': now0 + 5 * day, 'lease': await trialLeaseOf(s)}),
    });
    final b = instanceOver(fs, s, now: now0 + 1000, answers: {
      'trial': HttpResponse(200, {'trialStart': now0 - 2 * day, 'trialEndsAt': now0 + 3 * day, 'lease': await trialLeaseOf(s, days: 3)}),
    });
    await interleave(fs, a.startTrial, () async {
      await b.startTrial();
    });
    expect(savedIn(fs)['trialStart'], now0 - 9 * day);
    expect(savedIn(fs)['trialEndsAt'], now0 + 3 * day);
  });

  test('moves the kept major only up, whichever instance notes it last', () async {
    final s = await Signer.create();
    final window = (now0 + 10 * day) ~/ 1000;
    final lease = await s.lease(key1, major: openMajor, extra: {'upgradeUntil': window});
    final fs = oneFile({'key': key1, 'activationId': 'act_1', 'lease': lease, 'checkedMajor': 3, 'lastSeen': now0, 'rev': 1});
    // Neither server answers, so each run only notes the major it ran.
    final older = instanceOver(fs, s, now: now0, major: 2);
    final newer = instanceOver(fs, s, now: now0, major: 3);
    await interleave(fs, older.status, () async {
      await newer.status();
      expect(savedIn(fs)['keptMajor'], 3);
    });
    // The older run's note was merged again onto the newer one, and kept it.
    expect(fs.ops.where((op) => op.startsWith('create')), hasLength(3));
    expect(savedIn(fs)['keptMajor'], 3);
  });
}
