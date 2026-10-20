/// How the journal of unsynced spends and the figures beside it land on the
/// stored state (the SDK contract, 12.4; journal.ts): on the state as stored at
/// that moment, so two processes of one app never lose each other's spends.
library;

import 'meter_types.dart';
import 'meters.dart';
import 'stored_state.dart';

/// What a journal op does.
enum JournalOpKind { offline, unanswered, void_, confirmed, figures, activated, deactivated }

/// One change to the journal or its figures, about the activation [about].
final class JournalOp {
  const JournalOp.spend(this.kind, {required String this.about, required String this.id, required String this.meter, required int this.n, required int this.at, this.limit, this.told = false})
      : entries = const [],
        figures = const {};
  const JournalOp.confirmed(String this.about, this.entries)
      : kind = JournalOpKind.confirmed,
        id = null,
        meter = null,
        n = null,
        at = null,
        limit = null,
        told = false,
        figures = const {};
  const JournalOp.figures(String this.about, this.figures)
      : kind = JournalOpKind.figures,
        id = null,
        meter = null,
        n = null,
        at = null,
        limit = null,
        told = false,
        entries = const [];
  const JournalOp.activated(String this.about)
      : kind = JournalOpKind.activated,
        id = null,
        meter = null,
        n = null,
        at = null,
        limit = null,
        told = false,
        entries = const [],
        figures = const {};
  const JournalOp.deactivated()
      : kind = JournalOpKind.deactivated,
        about = null,
        id = null,
        meter = null,
        n = null,
        at = null,
        limit = null,
        told = false,
        entries = const [],
        figures = const {};

  final JournalOpKind kind;
  final String? about;
  final String? id;
  final String? meter;
  final int? n;
  final int? at;

  /// The most the meter's unsynced spends may come to with this spend.
  final int? limit;

  /// A spend the customer was told was made while a failed save kept it in
  /// memory: it lands whatever the limit and the cap say. Never read on a void.
  final bool told;
  final List<Confirmed> entries;
  final Map<String, MeterFigure> figures;

  bool get isAppend => kind == JournalOpKind.offline || kind == JournalOpKind.unanswered || kind == JournalOpKind.void_;

  SpendKind get spendKind => switch (kind) {
        JournalOpKind.offline => SpendKind.offline,
        JournalOpKind.unanswered => SpendKind.unanswered,
        _ => SpendKind.void_,
      };

  JournalOp withCount(int count) => JournalOp.spend(kind, about: about!, id: id!, meter: meter!, n: count, at: at!, limit: limit, told: told);
  JournalOp asTold() => JournalOp.spend(kind, about: about!, id: id!, meter: meter!, n: n!, at: at!, limit: limit, told: true);
}

/// The fields after an op; [refused] is true for a spend the full journal
/// could not take, or its limit forbids.
final class Journaled {
  const Journaled(this.spends, this.meterFigures, this.refused);
  final List<SpendEntry> spends;
  final Map<String, MeterFigure> meterFigures;
  final bool refused;

  Map<String, Object?> toJson() => {
        'spends': [for (final e in spends) e.toJson()],
        'meterFigures': meterFigures.map((code, f) => MapEntry(code, f.toJson())),
        'refused': refused,
      };
}

bool _confirms(SpendEntry entry, List<Confirmed> confirmed) => confirmed.any(
    (c) => c.id == entry.id && (c.isVoid ? entry.isVoid : !entry.isVoid && entry.n <= c.n!));

/// `stored` with the incoming figures, for each meter the newer by `at` kept.
Map<String, MeterFigure> newestFigures(Map<String, MeterFigure> stored, Map<String, MeterFigure> incoming) {
  final merged = Map.of(stored);
  for (final MapEntry(key: code, value: figure) in incoming.entries) {
    final held = merged[code];
    if (held == null || figure.at > held.at) merged[code] = figure;
  }
  return merged;
}

bool _toldOf(JournalOp op) => op.kind != JournalOpKind.void_ && op.told;

({List<SpendEntry> spends, bool refused}) _opened(List<SpendEntry> journal, JournalOp op) {
  final voids = journal.where((e) => e.isVoid).toList();
  final oldest = op.kind == JournalOpKind.void_ && voids.length >= maxPendingVoids ? voids.first : null;
  final room = oldest == null ? journal : [for (final e in journal) if (!identical(e, oldest)) e];
  if (room.length >= maxPendingSpends && !_toldOf(op)) return (spends: journal, refused: true);
  final entry = SpendEntry(id: op.id!, meter: op.meter!, n: op.n!, at: op.at!, kind: op.spendKind);
  return (spends: [...room, entry], refused: false);
}

({List<SpendEntry> spends, bool refused}) _appended(List<SpendEntry> journal, JournalOp op) {
  if (op.kind != JournalOpKind.offline && journal.any((e) => e.id == op.id)) return (spends: journal, refused: false);
  final limit = op.kind != JournalOpKind.void_ && !_toldOf(op) ? op.limit : null;
  if (limit != null && unsyncedOf(journal, op.meter!) + op.n! > limit) return (spends: journal, refused: true);
  final open = op.kind == JournalOpKind.offline
      ? journal.indexWhere((e) => e.kind == SpendKind.offline && e.meter == op.meter)
      : -1;
  if (open >= 0) {
    return (spends: [for (var i = 0; i < journal.length; i++) i == open ? journal[i].grown(op.n!) : journal[i]], refused: false);
  }
  return _opened(journal, op);
}

/// The journal and the figures after `op`, landed on `latest` at `now` (the
/// guarded clock): an op about another activation, or none, changes nothing; a
/// deactivation clears both, and an activation of another seat does; every op
/// that lands first drops the entries opened more than PENDING_MAX_MS before.
Journaled journaled(StoredState latest, JournalOp op, int now) {
  final spends = latest.spends;
  final figures = latest.meterFigures;
  if (op.kind == JournalOpKind.deactivated) return const Journaled([], {}, false);
  if (latest.activationId == null || latest.activationId != op.about) {
    return op.kind == JournalOpKind.activated ? const Journaled([], {}, false) : Journaled(spends, figures, false);
  }
  final live = [for (final e in spends) if (now - e.at <= pendingMaxMs) e];
  switch (op.kind) {
    case JournalOpKind.activated:
      return Journaled(live, figures, false);
    case JournalOpKind.confirmed:
      return Journaled([for (final e in live) if (!_confirms(e, op.entries)) e], figures, false);
    case JournalOpKind.figures:
      return Journaled(live, newestFigures(figures, op.figures), false);
    default:
      final landed = _appended(live, op);
      return Journaled(landed.spends, figures, landed.refused);
  }
}

/// A state with the journal fields `j` gives: an empty journal or no figures
/// is the field absent.
StoredState _withJournal(StoredState state, Journaled j) => state.patched({
      Field.spends: j.spends.isEmpty ? null : [for (final e in j.spends) e.toJson()],
      Field.meterFigures: j.meterFigures.isEmpty ? null : j.meterFigures.map((k, f) => MapEntry(k, f.toJson())),
    });

/// `ops` landed in order on `state` at `now`, and whether each was refused.
({StoredState state, List<bool> refused}) landJournal(StoredState state, List<JournalOp> ops, int now) {
  var current = state;
  final refused = <bool>[];
  for (final op in ops) {
    final landed = journaled(current, op, now);
    refused.add(landed.refused);
    current = _withJournal(current, landed);
  }
  return (state: current, refused: refused);
}

/// `ops` with neighbours folded together where landing them one after the
/// other lands what landing the fold does.
List<JournalOp> compacted(List<JournalOp> ops) {
  final out = <JournalOp>[];
  for (final op in ops) {
    final last = out.isEmpty ? null : out.last;
    if (last != null && last.about == op.about && last.kind == op.kind) {
      if (op.kind == JournalOpKind.offline && last.meter == op.meter) {
        out[out.length - 1] = last.withCount(last.n! + op.n!);
        continue;
      }
      if (op.kind == JournalOpKind.figures) {
        out[out.length - 1] = JournalOp.figures(op.about!, newestFigures(last.figures, op.figures));
        continue;
      }
      if (op.kind == JournalOpKind.confirmed) {
        out[out.length - 1] = JournalOp.confirmed(op.about!, _folded([...last.entries, ...op.entries]));
        continue;
      }
    }
    out.add(op);
  }
  return out;
}

/// Confirmations with each id once as a count and once as a void, the larger count kept.
List<Confirmed> _folded(List<Confirmed> entries) {
  final folded = <String, Confirmed>{};
  for (final c in entries) {
    final key = '${c.isVoid ? 'void' : 'count'} ${c.id}';
    final held = folded[key];
    if (held == null || (!c.isVoid && !held.isVoid && c.n! > held.n!)) folded[key] = c;
  }
  return folded.values.toList();
}

/// `ops` with all but the newest [maxPendingVoids] void ops dropped.
List<JournalOp> boundedVoids(List<JournalOp> ops) {
  final voids = [for (final op in ops) if (op.kind == JournalOpKind.void_) op];
  final drop = voids.take(voids.length > maxPendingVoids ? voids.length - maxPendingVoids : 0).toSet();
  return [for (final op in ops) if (!drop.contains(op)) op];
}
