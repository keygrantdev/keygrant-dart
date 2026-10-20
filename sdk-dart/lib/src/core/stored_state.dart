/// What the SDK keeps on disk (the SDK contract, 5.5): the stored state, with
/// the same field names every KeyGrant SDK uses, so a state file is portable
/// between them.
library;

import 'package:meta/meta.dart';

import 'json.dart';
import 'meter_types.dart';
import 'types.dart';

/// The stored state's field names.
abstract final class Field {
  static const key = 'key';
  static const activationId = 'activationId';
  static const lease = 'lease';
  static const trialStart = 'trialStart';
  static const trialEndsAt = 'trialEndsAt';
  static const trialLease = 'trialLease';
  static const trialAt = 'trialAt';
  static const lastSeen = 'lastSeen';
  static const checkedMajor = 'checkedMajor';
  static const keptMajor = 'keptMajor';
  static const backoffSince = 'backoffSince';
  static const backoffMs = 'backoffMs';
  static const refused = 'refused';
  static const refusedMajor = 'refusedMajor';
  static const refusedFor = 'refusedFor';
  static const deviceKind = 'deviceKind';
  static const verdictAt = 'verdictAt';
  static const rev = 'rev';
  static const trialReportedAt = 'trialReportedAt';
  static const licenseFile = 'licenseFile';
  static const spends = 'spends';
  static const meterFigures = 'meterFigures';
}

const _texts = {Field.key, Field.activationId, Field.lease, Field.trialLease, Field.licenseFile};

const _numbers = {
  Field.trialStart,
  Field.trialEndsAt,
  Field.trialAt,
  Field.lastSeen,
  Field.checkedMajor,
  Field.keptMajor,
  Field.backoffSince,
  Field.backoffMs,
  Field.refusedMajor,
  Field.verdictAt,
  Field.rev,
  Field.trialReportedAt,
};

/// What an earlier version stored to buy from the app with no key typed:
/// RETIRED, never read and left out of every save.
const retiredFields = {'purchaseToken', 'purchaseTokenAt', 'claimAskedAt'};

/// A change to the stored state: each member a field's new value, null to
/// clear it; a field the patch does not name is left as it is.
typedef StatePatch = Map<String, Object?>;

/// The licence state a device keeps between runs, one per product. Read-only:
/// the SDK saves a new one. A field this SDK does not know (a newer SDK's) is
/// kept as it was and written back.
final class StoredState {
  const StoredState._(this._fields);

  /// No state at all.
  static const StoredState empty = StoredState._({});

  /// The state a JSON value holds. A known field of the wrong type is left out
  /// (a number with a fraction is cut to a whole one); the journal and the
  /// figures are read leniently (an entry or a figure of another shape left
  /// out, an empty one absent); a retired field is not read; a field this SDK
  /// does not know is kept. A value that is no object holds no state.
  factory StoredState.fromJson(Object? json) {
    final members = json is List ? null : asObject(json);
    if (members == null) return empty;
    final fields = <String, Object?>{};
    for (final MapEntry(:key, :value) in members.entries) {
      if (retiredFields.contains(key)) continue;
      final read = _read(key, value);
      if (read != null) fields[key] = read;
    }
    return StoredState._(Map.unmodifiable(fields));
  }

  final Map<String, Object?> _fields;

  /// The fields as stored, normalized: what [toJson] writes.
  @internal
  Map<String, Object?> get fields => _fields;

  /// The state as a JSON object, under the field names every KeyGrant SDK uses.
  Map<String, Object?> toJson() => Map.of(_fields);

  /// This state with `patch` applied: each member set (as [StoredState.fromJson]
  /// reads it), a null one cleared. A field the patch does not name keeps its
  /// value, the same object.
  @internal
  StoredState patched(StatePatch patch) {
    final next = Map.of(_fields);
    for (final MapEntry(:key, :value) in patch.entries) {
      final read = value == null || retiredFields.contains(key) ? null : _read(key, value);
      if (read == null) {
        next.remove(key);
      } else {
        next[key] = read;
      }
    }
    return StoredState._(Map.unmodifiable(next));
  }

  String? get key => _fields[Field.key] as String?;
  String? get activationId => _fields[Field.activationId] as String?;

  /// The signed lease of a paid licence.
  String? get lease => _fields[Field.lease] as String?;

  /// The earliest trial start ever seen (ms). Only ever moves earlier.
  int? get trialStart => _fields[Field.trialStart] as int?;

  /// The server's trial end (ms), unsigned.
  int? get trialEndsAt => _fields[Field.trialEndsAt] as int?;

  /// The signed lease of a trial.
  String? get trialLease => _fields[Field.trialLease] as String?;

  /// When (the guarded clock) the trial answer stored here was asked for.
  int? get trialAt => _fields[Field.trialAt] as int?;

  /// The highest device time ever seen: the guard against putting the clock back.
  int? get lastSeen => _fields[Field.lastSeen] as int?;

  /// The app major sent with the last check-in the server answered.
  int? get checkedMajor => _fields[Field.checkedMajor] as int?;

  /// The newest app major run while holding a lease inside the key's upgrade window.
  int? get keptMajor => _fields[Field.keptMajor] as int?;

  /// When (the device clock) the last ask came back without a lease, and how
  /// long to wait after it.
  int? get backoffSince => _fields[Field.backoffSince] as int?;
  int? get backoffMs => _fields[Field.backoffMs] as int?;

  /// The server's definitive refusal of this key on this device.
  Refusal? get refused => Refusal.fromWire(_fields[Field.refused]);

  /// The build major an `upgrade` or `outdated` refusal was given for.
  int? get refusedMajor => _fields[Field.refusedMajor] as int?;

  /// The device a `device` refusal was given for (its own claim hash).
  List<String>? get refusedFor => (_fields[Field.refusedFor] as List?)?.cast<String>();

  /// What this install is keyed by: the kind, never a fingerprint.
  DeviceKind? get deviceKind => DeviceKind.fromWire(_fields[Field.deviceKind]);

  /// When (the guarded clock) the server's answer stored here was asked for.
  int? get verdictAt => _fields[Field.verdictAt] as int?;

  /// The default storage's revision of this state, one more on every save.
  int? get rev => _fields[Field.rev] as int?;

  /// When (the guarded clock) a running trial last reported its launch.
  int? get trialReportedAt => _fields[Field.trialReportedAt] as int?;

  /// The stored offline licence file's token.
  String? get licenseFile => _fields[Field.licenseFile] as String?;

  /// The journal of this device's unsynced spends, oldest first; empty for none.
  List<SpendEntry> get spends => [
        for (final entry in (_fields[Field.spends] as List?) ?? const []) SpendEntry.fromJson(entry)!,
      ];

  /// The newest figures a `use` answer gave, by meter; empty for none.
  Map<String, MeterFigure> get meterFigures => {
        for (final MapEntry(:key, :value) in ((_fields[Field.meterFigures] as Map?) ?? const {}).entries)
          key as String: MeterFigure.fromJson(value)!,
      };

  @override
  bool operator ==(Object other) => other is StoredState && jsonEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAllUnordered(_fields.keys);

  @override
  String toString() => 'StoredState($_fields)';
}

/// A field's value as the state keeps it, or null when it is not of its type.
Object? _read(String field, Object? value) {
  if (_texts.contains(field)) return value is String ? value : null;
  if (_numbers.contains(field)) return _whole(value);
  switch (field) {
    case Field.refused:
      return Refusal.fromWire(value)?.wire;
    case Field.deviceKind:
      return DeviceKind.fromWire(value)?.wire;
    case Field.refusedFor:
      return value is List ? List<String>.unmodifiable(value.whereType<String>()) : null;
    case Field.spends:
      final journal = spendsOf(value);
      return journal.isEmpty ? null : List.unmodifiable([for (final e in journal) e.toJson()]);
    case Field.meterFigures:
      final figures = storedFigures(value);
      return figures.isEmpty ? null : Map.unmodifiable(figures.map((k, f) => MapEntry(k, f.toJson())));
  }
  return value;
}

/// A stored number as a whole one: a fraction cut toward zero, anything that
/// is no finite number none.
int? _whole(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value.abs() < 9.2e18) return value.truncate();
  return null;
}

/// The journal a stored `spends` is: its entries in order, anything that is
/// not a list or an entry left out.
List<SpendEntry> spendsOf(Object? stored) =>
    stored is List ? [for (final e in stored) if (SpendEntry.fromJson(e) case final entry?) entry] : const [];

/// The figures a stored `meterFigures` holds, by code: a member that is not a
/// whole figure set with a time is left out.
Map<String, MeterFigure> storedFigures(Object? stored) {
  final all = stored is List ? null : asObject(stored);
  if (all == null) return const {};
  return {
    for (final MapEntry(:key, :value) in all.entries)
      if (MeterFigure.fromJson(value) case final figure?) key: figure,
  };
}
