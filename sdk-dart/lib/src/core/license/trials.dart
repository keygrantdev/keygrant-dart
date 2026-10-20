part of 'license.dart';

/// The trial machinery (trials.ts): asking the server for this device's trial
/// and saving its answer, even when the disk refuses it for now; a trial's
/// status; asking again for a trial whose lease does not verify while its
/// stored end is ahead; and a running trial's launch, reported at most once a
/// day in the background.
abstract class _TrialEngine extends _CheckinEngine {
  _TrialEngine(super.config, super.timing);

  /// The server's trial when it could not be saved, kept for this process.
  ({StatePatch patch, Basis basis})? _unsavedTrial;

  /// The launch report in flight, which the SDK itself never awaits.
  Future<void> _launch = Future.value();

  /// The stored state for a status, with a trial this process could not
  /// save; null when it cannot be read just now.
  Future<StoredState?> _loadForStatus(bool readOnly) async {
    StoredState state;
    try {
      state = await _load(readOnly);
    } catch (_) {
      return null;
    }
    final unsaved = _unsavedTrial;
    return unsaved == null ? state : merged(state, unsaved.patch, unsaved.basis);
  }

  /// Save the trial this process could not, and forget it once saved.
  Future<void> _saveUnsavedTrial() async {
    final unsaved = _unsavedTrial;
    if (unsaved != null && await _saveBestEffort(unsaved.patch, null, unsaved.basis)) _unsavedTrial = null;
  }

  Future<LicenseStatus> _startTrialNow(StoredState state) async {
    final asked = await _askTrial(state, _timing.activateMachineId);
    return _trialStatus(asked.latest, _effectiveNow(state));
  }

  /// Ask the server for this device's trial (`trial`, with the earliest start
  /// the device holds as `clientStart`) and save its answer.
  Future<({bool reached, StoredState latest})> _askTrial(StoredState state, Duration machineIdTimeout,
      [Duration? timeout]) async {
    final device = await _device(machineIdTimeout, state.deviceKind);
    final regStart = await _settle(_registry.readTrialStart, null);
    final clientStart = earliest<num>([state.trialStart, regStart]);
    final own = device.own;
    if (own == null) return (reached: false, latest: state);
    final asked = Stamp(at: _effectiveNow(state), seen: state.trialAt);
    final body = withoutNulls({'fingerprint': own, 'fingerprintKind': device.kind?.wire, 'clientStart': clientStart});
    HttpResponse res;
    try {
      res = await _post('trial', body, timeout);
    } catch (_) {
      return (reached: false, latest: state);
    }
    final trial = res.status == 200 ? parseTrialBody(res.json) : null;
    if (trial == null || !trial.trialStart.isFinite || !trial.trialEndsAt.isFinite) return (reached: true, latest: state);
    return (reached: true, latest: await _takeTrial(state, trial, regStart, asked));
  }

  /// The server's trial, saved as the answer to its ask, or kept for this
  /// process when the disk refuses it: the state with it merged in.
  Future<StoredState> _takeTrial(StoredState state, ({num trialStart, num trialEndsAt, String? lease}) body, int? regStart,
      Stamp asked) async {
    final trialStart = earliest<num>([body.trialStart, state.trialStart, regStart])!.toInt();
    await _settle(() => _registry.writeTrialStart(trialStart), null);
    final keep = await _keepsItsTrialLease(state, body.lease);
    final trial = {
      Field.trialStart: trialStart,
      Field.trialEndsAt: body.trialEndsAt.toInt(),
      Field.trialLease: keep ? state.trialLease : body.lease,
    };
    final basis = Basis(trial: asked);
    _unsavedTrial = await _saveBestEffort(trial, null, basis) ? null : (patch: trial, basis: basis);
    return merged(state, trial, basis);
  }

  /// Whether a trial answer's lease fails here while the stored one verifies.
  Future<bool> _keepsItsTrialLease(StoredState state, String? answered) async {
    final stored = state.trialLease;
    if (answered == null || stored == null) return false;
    final now = _effectiveNow(state);
    if ((await _trialLease(answered, now, state.deviceKind)).valid) return false;
    return (await _trialLease(stored, now, state.deviceKind)).valid;
  }

  /// A trial's status from what the device holds; with `ask` (a `status()`),
  /// a trial whose lease does not verify while its stored end is ahead is
  /// asked for again first, and a running one reports its launch when due.
  Future<LicenseStatus> _trialStatus(StoredState state, int now, {bool? forceOnline, bool readOnly = true}) async {
    final stored = state.trialLease;
    final lease = stored == null ? const TrialLease.invalid() : await _trialLease(stored, now, state.deviceKind);
    final status = trialStatusOf(state, now, lease.valid, lease.endsAt, lease.entitlements);
    if (forceOnline == null || readOnly) return status;
    if (status.state == LicenseState.trial) {
      await _reportLaunch(state, now);
      return status;
    }
    final end = state.trialEndsAt;
    if (lease.valid || end == null || now >= end) return status;
    return await _healTrial(state, forceOnline) ?? status;
  }

  /// A running trial's launch, reported at most once a day with no key held:
  /// the stamp saved first (nothing is sent when it cannot be), then `trial`
  /// POSTed in the background, never awaited.
  Future<void> _reportLaunch(StoredState state, int now) async {
    if ((state.key ?? '').isNotEmpty || !trialReportDue(state, now)) return;
    if (!await _saveBestEffort({Field.trialReportedAt: now})) return;
    _launch = _sendLaunch(state).catchError((Object _) {});
  }

  Future<void> _sendLaunch(StoredState state) async {
    final device = await _device(_timing.machineId, state.deviceKind);
    final own = device.own;
    if (own == null) return;
    final body = withoutNulls({'fingerprint': own, 'fingerprintKind': device.kind?.wire, 'clientStart': state.trialStart});
    await _post('trial', body, _timing.statusCheck);
  }

  /// A trial whose lease does not verify here while its stored end is ahead,
  /// asked for again under the usual waits; the wait starts when that brings
  /// back no trial this build can verify. Null when it did not ask, or nothing answered.
  Future<LicenseStatus?> _healTrial(StoredState state, bool forceOnline) async {
    final askedAt = _clock.now();
    if (!askDue(state, askedAt, forceOnline)) return null;
    final asked = await _askTrial(state, _timing.machineId, _timing.statusCheck);
    final after = asked.reached ? await _trialStatus(asked.latest, _effectiveNow(asked.latest)) : null;
    if (after?.state == LicenseState.trial) return after;
    await _saveBestEffort({Field.backoffSince: askedAt, Field.backoffMs: asked.reached ? askAgainMs : retryUnansweredMs});
    return after;
  }
}

/// `work`'s answer, or `fallback` when it throws.
Future<T> _settle<T>(Future<T> Function() work, T fallback) async {
  try {
    return await work();
  } catch (_) {
    return fallback;
  }
}
