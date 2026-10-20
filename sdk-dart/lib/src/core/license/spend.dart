part of 'license.dart';

/// One call to `use()`, as the steps below read it.
final class _Spending {
  const _Spending(this.state, this.claims, this.meter, this.n, this.id, this.at, this.readOnly, this.verdict);

  /// The state the call read, with what this process could not save landed on it.
  final StoredState state;
  final LeaseClaims claims;
  final String meter;
  final int n;
  final String id;

  /// When (the guarded clock) the spend is made.
  final int at;

  /// Behind a call that has not finished: nothing is saved.
  final bool readOnly;

  /// What the offline allowance says of the spend as the call read the state.
  final OfflineSpend verdict;

  String get about => state.activationId!;
}

/// Spending a key's meters (spend.ts): `use(meter, n)` asks the server when it
/// should, and when it gets no answer spends from the device's offline
/// allowance, keeping the spend in the journal to report with the next request.
abstract class _MeterEngine extends _FileEngine {
  _MeterEngine(super.config, super.timing);

  /// The claims of the key's lease when what is stored licenses this build by a key's lease.
  Future<LeaseClaims?> _keyClaims(StoredState state);

  /// Spend `n` of `meter`. Never throws: what cannot be told is `storage`.
  Future<UseResult> _useMeter(String meter, int n) async {
    final asked = askedFor(meter, n);
    if (asked.refused != null) return UseRefused(asked.refused!);
    try {
      return await _serial((readOnly) => _spend(asked.meter!, asked.n!, readOnly));
    } catch (_) {
      return const UseRefused(UseError.storage);
    }
  }

  Future<UseResult> _spend(String meter, int n, bool readOnly) async {
    if (!readOnly) await _saveUnsavedJournal();
    final state = await _loadForStatus(readOnly);
    if (state == null) return const UseRefused(UseError.storage);
    final claims = await _keyClaims(state);
    if (claims == null || state.activationId == null) return const UseRefused(UseError.notLicensed);
    final at = _effectiveNow(state);
    final verdict = offlineSpend(figuresFor(claims, state), state.spends, meter, n);
    final sp = _Spending(state, claims, meter, n, newSpendId(), at, readOnly, verdict);
    var sent = false;
    if (useAsksNow(state: state, clockNow: _clock.now(), now: at, covered: verdict.ok)) {
      final online = await _askToSpend(sp);
      if (online != null) return online;
      sent = true;
    }
    return _spendOffline(sp, sent);
  }

  /// Ask the server to spend, with the journal's report; its answer saved as a
  /// validate's is unless this call is behind one that has not finished. Null
  /// when there was no usable answer: the spend is in doubt.
  Future<UseResult?> _askToSpend(_Spending sp) async {
    final state = sp.state;
    final askedAt = _clock.now();
    final asked = Asked(at: sp.at, activationId: state.activationId, seen: state.verdictAt);
    final device = await _device(_timing.machineId, state.deviceKind);
    final reports = spendsReported(await _reportable(state));
    final body = {
      ..._deviceBody(state, device),
      'meter': sp.meter,
      'n': sp.n,
      'id': sp.id,
      if (reports != null) 'spends': reports,
      'kids': _keyIds,
    };
    HttpResponse? response;
    try {
      response = await _post('use', body, _boundedBy(_timing.statusCheck));
    } catch (_) {
      response = null;
    }
    final outcome = useOutcome(response: response, askedAt: askedAt, major: _major, kind: device.kind, ownClaim: device.ownClaim);
    final ops = _journalOps(state, outcome);
    // A verdict or a wait is the answer to an ask; figures and confirmations are not.
    final answer = outcome.patch.isNotEmpty ? Basis(answer: asked) : const Basis();
    if (!sp.readOnly && (ops.isNotEmpty || outcome.patch.isNotEmpty)) await _saveOps(state, outcome.patch, answer, ops);
    if (outcome.outcome == UseOutcomeKind.unanswered) return null;
    return _answered(outcome, sp, landJournal(state, ops, sp.at).state);
  }

  /// With no answer (or none asked): spend from the allowance; refused, a
  /// spend in doubt is journaled as a `void`, and so is one the landing refuses.
  Future<UseResult> _spendOffline(_Spending sp, bool doubt) async {
    final verdict = sp.verdict;
    if (!verdict.ok) {
      if (doubt) await _journal(sp, [_entry(sp, JournalOpKind.void_)]);
      return verdict.error == UseError.noMeter
          ? const UseRefused(UseError.noMeter)
          : UseRefused(UseError.offlineLimit, verdict.left);
    }
    final kind = doubt ? JournalOpKind.unanswered : JournalOpKind.offline;
    final [refused] = await _journal(sp, [_entry(sp, kind, limit: verdict.limit)]);
    if (refused) {
      if (doubt) await _journal(sp, [_entry(sp, JournalOpKind.void_)]);
      return UseRefused(UseError.offlineLimit, await _landedLeft(sp));
    }
    return UseSpent(verdict.left!, offline: true);
  }

  JournalOp _entry(_Spending sp, JournalOpKind kind, {int? limit}) =>
      JournalOp.spend(kind, about: sp.about, id: sp.id, meter: sp.meter, n: sp.n, at: sp.at, limit: limit);

  /// What is left of the meter by the state as a refused landing found it; 0
  /// when the state cannot be read just now.
  Future<int> _landedLeft(_Spending sp) async {
    final fresh = await _loadForStatus(sp.readOnly);
    if (fresh == null) return 0;
    final figure = figuresFor(sp.claims, fresh)[sp.meter];
    if (figure == null) return 0;
    final left = figure.left - unsyncedOf(fresh.spends, sp.meter);
    return left < 0 ? 0 : left;
  }

  /// `ops` saved, or kept in memory when this call may save nothing or the disk refuses.
  Future<List<bool>> _journal(_Spending sp, List<JournalOp> ops) async =>
      sp.readOnly ? _keepUnsaved(sp.state, ops) : await _saveOps(sp.state, const {}, const Basis(), ops);
}

/// The journal changes an answer makes: the reports it confirms and the figures it gives.
List<JournalOp> _journalOps(StoredState state, UseOutcome outcome) {
  final about = state.activationId;
  if (about == null) return const [];
  return [
    if (outcome.confirmed.isNotEmpty) JournalOp.confirmed(about, outcome.confirmed),
    if (outcome.figures.isNotEmpty) JournalOp.figures(about, outcome.figures),
  ];
}

/// What `use()` answers for an answer the server gave.
UseResult _answered(UseOutcome outcome, _Spending sp, StoredState after) {
  switch (outcome.outcome) {
    case UseOutcomeKind.spent:
      final figure = figuresFor(sp.claims, after)[sp.meter];
      final left = figure == null ? 0 : figure.left - unsyncedOf(after.spends, sp.meter);
      return UseSpent(left < 0 ? 0 : left);
    case UseOutcomeKind.usedUp:
      return UseRefused(UseError.usedUp, outcome.left);
    case UseOutcomeKind.noMeter:
      return const UseRefused(UseError.noMeter);
    default:
      return UseRefused(switch (outcome.refusal) {
        Refusal.revoked => UseError.revoked,
        Refusal.upgrade => UseError.upgrade,
        Refusal.outdated => UseError.outdated,
        Refusal.device => UseError.device,
        null => UseError.notLicensed,
      });
  }
}
