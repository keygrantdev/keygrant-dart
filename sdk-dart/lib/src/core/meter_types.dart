/// The types of metered uses (the SDK contract, section 12): what a lease
/// signs of a meter, what a `use` answer gives, what the journal keeps, and
/// what `status().meters` shows.
library;

import 'json.dart';

/// A meter's figures as a lease signs them (`met`) or an answer gives them,
/// without the time of the answer: what was left, the uses it holds, the
/// offline allowance each device may spend, and whether it comes back each
/// billing period.
final class BaseFigure {
  const BaseFigure({required this.left, required this.total, required this.offline, required this.resets});

  final int left;
  final int total;
  final int offline;
  final bool resets;

  Map<String, Object?> toJson() => {'left': left, 'total': total, 'offline': offline, 'resets': resets};

  @override
  bool operator ==(Object other) =>
      other is BaseFigure &&
      other is! MeterFigure &&
      other.left == left &&
      other.total == total &&
      other.offline == offline &&
      other.resets == resets;

  @override
  int get hashCode => Object.hash(left, total, offline, resets);
}

/// One meter as a lease's `met` claim signs it.
typedef MeterClaim = BaseFigure;

/// A meter's figures as the newest `use` answer gave them; [at] is the
/// server's time (ms).
final class MeterFigure extends BaseFigure {
  const MeterFigure({required super.left, required super.total, required super.offline, required super.resets, required this.at});

  final int at;

  BaseFigure get base => BaseFigure(left: left, total: total, offline: offline, resets: resets);

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'at': at};

  @override
  bool operator ==(Object other) =>
      other is MeterFigure &&
      other.left == left &&
      other.total == total &&
      other.offline == offline &&
      other.resets == resets &&
      other.at == at;

  @override
  int get hashCode => Object.hash(left, total, offline, resets, at);

  /// A stored figure, or null when it is not a whole figure set with a time.
  static MeterFigure? fromJson(Object? json) {
    final f = asObject(json);
    if (f == null || json is List) return null;
    final left = figureOf(f['left']), total = figureOf(f['total']), offline = figureOf(f['offline']), at = figureOf(f['at']);
    if (left == null || total == null || offline == null || at == null) return null;
    return MeterFigure(left: left, total: total, offline: offline, resets: f['resets'] == true, at: at);
  }
}

/// One meter of a key as `status().meters` shows it: what is left net of this
/// device's unsynced spends (never below 0), the uses it holds, its offline
/// allowance, the uses this device spent that KeyGrant has not heard of, and
/// whether it comes back each billing period.
final class MeterStatus {
  const MeterStatus({
    required this.left,
    required this.total,
    required this.offline,
    required this.unsynced,
    required this.resets,
  });

  final int left;
  final int total;
  final int offline;
  final int unsynced;
  final bool resets;

  Map<String, Object?> toJson() =>
      {'left': left, 'total': total, 'offline': offline, 'unsynced': unsynced, 'resets': resets};

  @override
  bool operator ==(Object other) =>
      other is MeterStatus &&
      other.left == left &&
      other.total == total &&
      other.offline == offline &&
      other.unsynced == unsynced &&
      other.resets == resets;

  @override
  int get hashCode => Object.hash(left, total, offline, unsynced, resets);
}

/// What kind of entry the journal holds: spends made with no request sent
/// (one entry for each meter, growing), one spend whose own request got no
/// answer, or one such spend refused after (reported so the server takes it back).
enum SpendKind {
  offline('offline'),
  unanswered('unanswered'),
  void_('void');

  const SpendKind(this.wire);

  /// The kind as the stored state writes it.
  final String wire;

  static SpendKind? fromWire(Object? word) => switch (word) {
        'offline' => SpendKind.offline,
        'unanswered' => SpendKind.unanswered,
        'void' => SpendKind.void_,
        _ => null,
      };
}

/// A spend this device made that KeyGrant has not confirmed (the journal).
final class SpendEntry {
  const SpendEntry({required this.id, required this.meter, required this.n, required this.at, required this.kind});

  final String id;
  final String meter;
  final int n;

  /// When (the guarded device clock, ms) the entry was opened.
  final int at;
  final SpendKind kind;

  bool get isVoid => kind == SpendKind.void_;

  Map<String, Object?> toJson() => {'id': id, 'meter': meter, 'n': n, 'at': at, 'kind': kind.wire};

  SpendEntry grown(int more) => SpendEntry(id: id, meter: meter, n: n + more, at: at, kind: kind);

  /// A stored entry, or null when it is not one the journal holds: the state
  /// is the device's own, never the server's word. Unknown members are dropped.
  static SpendEntry? fromJson(Object? json) {
    final e = json is List ? null : asObject(json);
    if (e == null) return null;
    final id = e['id'], meter = e['meter'], n = safeWholeOf(e['n']), at = figureOf(e['at']);
    final kind = SpendKind.fromWire(e['kind']);
    if (id is! String || meter is! String || n == null || n < 1 || at == null || kind == null) return null;
    return SpendEntry(id: id, meter: meter, n: n, at: at, kind: kind);
  }

  @override
  bool operator ==(Object other) =>
      other is SpendEntry && other.id == id && other.meter == meter && other.n == n && other.at == at && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, meter, n, at, kind);
}

/// A report the server names as recorded: how many it holds of a spend, or
/// that it took a void.
final class Confirmed {
  const Confirmed.count(this.id, int this.n) : isVoid = false;
  const Confirmed.voided(this.id)
      : n = null,
        isVoid = true;

  final String id;
  final int? n;
  final bool isVoid;

  Map<String, Object?> toJson() => isVoid ? {'id': id, 'void': true} : {'id': id, 'n': n};
}
