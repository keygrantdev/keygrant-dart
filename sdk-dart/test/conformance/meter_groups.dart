// The metered-uses groups (the SDK contract, 12.11), answered as
// the reference's replay-meters.ts answers them.

import 'dart:convert';

import 'package:keygrant/src/core/journal.dart';
import 'package:keygrant/src/core/lease.dart';
import 'package:keygrant/src/core/meter_types.dart';
import 'package:keygrant/src/core/meters.dart';
import 'package:keygrant/src/core/offline.dart';
import 'package:keygrant/src/core/stored_state.dart';
import 'package:keygrant/src/core/types.dart';
import 'package:keygrant/src/core/use_outcome.dart';

import 'device_groups.dart';
import 'harness.dart';
import 'inputs.dart';

/// Base figures as a vector gives them, by code.
Map<String, BaseFigure> baseFiguresOf(Object? json) => {
      for (final MapEntry(:key, :value) in ((json as Map<String, Object?>?) ?? const {}).entries)
        key: _figure(value as Map<String, Object?>),
    };

BaseFigure _figure(Map<String, Object?> f) => BaseFigure(
      left: intOr(f['left'])!,
      total: intOr(f['total'])!,
      offline: intOr(f['offline'])!,
      resets: f['resets'] == true,
    );

/// A journal as a vector gives it.
List<SpendEntry> spendsOfJson(Object? json) => spendsOf(json);

/// A journal op as a vector gives it.
JournalOp opOf(Map<String, Object?> o) {
  final about = o['about'] as String?;
  switch (o['kind']) {
    case 'confirmed':
      return JournalOp.confirmed(about!, [
        for (final c in o['entries'] as List)
          if ((c as Map)['void'] == true) Confirmed.voided(c['id'] as String) else Confirmed.count(c['id'] as String, intOr(c['n'])!),
      ]);
    case 'figures':
      return JournalOp.figures(about!, storedFigures(o['figures']));
    case 'activated':
      return JournalOp.activated(about!);
    case 'deactivated':
      return const JournalOp.deactivated();
  }
  final kind = switch (o['kind']) {
    'offline' => JournalOpKind.offline,
    'unanswered' => JournalOpKind.unanswered,
    _ => JournalOpKind.void_,
  };
  return JournalOp.spend(kind,
      about: about!,
      id: o['id'] as String,
      meter: o['meter'] as String,
      n: intOr(o['n'])!,
      at: intOr(o['at'])!,
      limit: intOr(o['limit']),
      told: o['told'] == true);
}

void meterGroups() {
  conformanceGroup('meterClaims', (v) {
    final json = v['json'] as String?;
    final met = metersOf(json == null ? null : jsonDecode(json));
    return {'expect': met.map((code, m) => MapEntry(code, m.toJson()))};
  });
  conformanceGroup('meterLeases', (v) async {
    final verified = await verifyLease(v['token'] as String, fileKeys(), intOr(v['now'])!);
    final check = checkLease(verified, v['product'] as String, intOr(v['major'])!, holderOf(v['holder']));
    return {'verify': verified.toJson(), 'expect': check.toJson()};
  });
  conformanceGroup('useAmounts', (v) {
    final meter = v['meter'] as String;
    final asked = v.containsKey('n') ? askedFor(meter, intOr(v['n'])!) : askedFor(meter);
    return {'expect': asked.toJson()};
  });
  conformanceGroup('meterFigures', (v) {
    final figures = figuresOf(baseFiguresOf(v['met']), intOr(v['iat'])!, storedFigures(v['figures']));
    return {'expect': figures.map((code, f) => MapEntry(code, f.toJson()))};
  });
  conformanceGroup('meterStatuses', (v) {
    final meters = meterStatusOf(baseFiguresOf(v['figures']), spendsOfJson(v['spends']));
    return {'expect': meters.map((code, m) => MapEntry(code, m.toJson()))};
  });
  conformanceGroup('offlineSpends', (v) {
    final spend = offlineSpend(baseFiguresOf(v['figures']), spendsOfJson(v['spends']), v['meter'] as String, intOr(v['n'])!);
    return {'expect': spend.toJson()};
  });
  conformanceGroup('useAsks', (v) {
    final asks = useAsksNow(
      state: stateOf(v['state']),
      clockNow: intOr(v['clockNow'])!,
      now: intOr(v['now'])!,
      covered: v['covered'] as bool,
    );
    return {'expect': asks};
  });
  conformanceGroup('syncAsks', validLeaseAsk);
  conformanceGroup('useOutcomes', (v) {
    final d = v['device'] as Map<String, Object?>;
    final outcome = useOutcome(
      response: responseOf(v['response']),
      askedAt: intOr(v['askedAt'])!,
      major: intOr(v['major'])!,
      kind: DeviceKind.fromWire(d['kind']),
      ownClaim: d['ownClaim'] as String?,
    );
    return {'expect': outcome.toJson()};
  });
  conformanceGroup('journals', (v) {
    final landed = journaled(StoredState.fromJson(v['latest']), opOf(v['op'] as Map<String, Object?>), intOr(v['now'])!);
    return {'expect': landed.toJson()};
  });
  conformanceGroup('spendReports', (v) => {'expect': spendsReported(spendsOfJson(v['spends']))});
  conformanceGroup('spendConfirmations', (v) {
    return {'expect': [for (final c in spendsConfirmed(responseOf(v['response']))) c.toJson()]};
  });
}
