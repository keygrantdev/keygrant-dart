/// How a save lands on the state as stored at that moment (the SDK contract,
/// 5.5; merge.ts `merged`): by what it is based on, which of its fields an
/// answer already out of date, or one about an activation no longer stored,
/// may still write.
library;

import 'stored_state.dart';
import 'wire.dart';

/// When something was asked of the server (the guarded clock, ms), and the
/// stored stamp of that kind the asker saw.
class Stamp {
  const Stamp({required this.at, this.seen});

  final int at;
  final int? seen;
}

/// An ask of the server about an activation.
final class Asked extends Stamp {
  const Asked({required super.at, super.seen, this.activationId});

  /// The activation it asked about.
  final String? activationId;
}

/// What a save is based on.
final class Basis {
  const Basis({this.answer, this.activation, this.about, this.trial, this.aboutSet = false});

  /// A note about the activation [about] names (not an answer).
  const Basis.about(this.about)
      : answer = null,
        activation = null,
        trial = null,
        aboutSet = true;

  /// The answer to an ask about an activation: stamped `verdictAt`.
  final Asked? answer;

  /// An activation's answer, about the activation it names: stamped `verdictAt`.
  final Asked? activation;

  /// The activation a save that is not an answer is about.
  final String? about;

  /// Whether the save is about an activation ([about] may name none).
  final bool aboutSet;

  /// The server's answer to a trial ask: stamped `trialAt`.
  final Stamp? trial;
}

const _verdictFields = [
  Field.lease,
  Field.refused,
  Field.refusedMajor,
  Field.refusedFor,
  Field.backoffSince,
  Field.backoffMs,
  Field.checkedMajor,
  Field.verdictAt,
];

const _trialAnswerFields = [Field.trialEndsAt, Field.trialLease, Field.trialAt];

const _trialFields = [Field.trialStart, ..._trialAnswerFields];

/// Whether a stored stamp is a NEWER answer than `stamp`'s: saved since that
/// asker read the state, and asked for later than it.
bool outdated(int? stored, Stamp stamp) => stored != stamp.seen && stored != null && stored > stamp.at;

/// Whether an ask's answer is out of date by the time it is saved: about
/// another activation, or a newer answer about the same one saved since.
Superseded? superseded(StoredState latest, Asked asked) {
  if (latest.activationId != asked.activationId) return Superseded.activation;
  return outdated(latest.verdictAt, asked) ? Superseded.answer : null;
}

/// How out of date an answer is when it is saved.
enum Superseded { activation, answer }

StatePatch _omit(StatePatch patch, List<String> fields) => {
      for (final MapEntry(:key, :value) in patch.entries)
        if (!fields.contains(key)) key: value,
    };

/// A patch without the verdict fields: what of an out-of-date answer is still saved.
StatePatch withoutVerdict(StatePatch patch) => _omit(patch, _verdictFields);

/// Only the trial evidence of a patch: what lands on another activation.
StatePatch trialOnly(StatePatch patch) => {
      for (final field in _trialFields)
        if (patch.containsKey(field)) field: patch[field],
    };

Superseded? _outOfDate(StoredState latest, Basis basis) {
  final answer = basis.answer, activation = basis.activation;
  if (answer != null) return superseded(latest, answer);
  if (activation != null) {
    final same = latest.activationId == activation.activationId;
    return same && outdated(latest.verdictAt, activation) ? Superseded.answer : null;
  }
  if (basis.aboutSet && latest.activationId != basis.about) return Superseded.activation;
  return null;
}

/// A patch merged onto the state as stored now, by what it is based on
/// (merge.ts `merged`): stamped, a save about an activation no longer stored
/// keeping only its trial evidence, an older answer losing its verdict fields,
/// an older trial answer its end and lease; the trial start only ever earlier,
/// the stored activation's kept major only ever up; the retired fields left out.
StoredState merged(StoredState latest, StatePatch patch, [Basis basis = const Basis()]) {
  final stamp = basis.answer ?? basis.activation;
  var applied = <String, Object?>{
    ...patch,
    if (stamp != null) Field.verdictAt: stamp.at,
    if (basis.trial != null) Field.trialAt: basis.trial!.at,
  };
  final state = _outOfDate(latest, basis);
  if (state == Superseded.activation) applied = trialOnly(applied);
  if (state == Superseded.answer) applied = withoutVerdict(applied);
  if (basis.trial != null && outdated(latest.trialAt, basis.trial!)) applied = _omit(applied, _trialAnswerFields);
  final trialStart = earliest<num>([latest.trialStart, applied[Field.trialStart] as num?]);
  final result = latest.patched({...applied, if (trialStart != null) Field.trialStart: trialStart});
  final about = stamp != null ? stamp.activationId : basis.about;
  final hasAbout = stamp != null || basis.aboutSet;
  return _keptHighest(result, latest, applied, hasAbout, about);
}

StoredState _keptHighest(StoredState result, StoredState latest, StatePatch applied, bool hasAbout, String? about) {
  if (!hasAbout || latest.activationId != about) return result;
  final kept = [latest.keptMajor, applied[Field.keptMajor] as num?].whereType<num>();
  if (kept.isEmpty) return result;
  return result.patched({Field.keptMajor: kept.reduce((a, b) => a > b ? a : b)});
}
