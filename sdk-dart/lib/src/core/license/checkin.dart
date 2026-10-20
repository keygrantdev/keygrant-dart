part of 'license.dart';

/// The outcome of an online validate: the server's verdict, or no answer at all.
typedef _Renewal = ({bool answered, LicenseStatus? status});

/// The online validate under [KeyGrantLicense] (checkin.ts): the request a
/// renewal makes, the lease its answer carries judged on this device, what
/// the answer saves (renewal.ts `renewalOutcome`), and the journal it reports.
abstract class _CheckinEngine extends _Engine {
  _CheckinEngine(super.config, super.timing);

  /// An online validate; a status on a definitive answer, else null.
  Future<LicenseStatus?> _tryRenew(StoredState state, [Duration? timeout]) async {
    final renewal = await _renew(state, timeout);
    return renewal.answered ? renewal.status : null;
  }

  /// An online validate, and whether the server gave a verdict: saved as the
  /// answer to its ask, the journal's confirmations dropped with it; an answer
  /// that confirms none of a report starts the wait of an answer without a lease.
  Future<_Renewal> _renew(StoredState state, [Duration? timeout]) async {
    final askedAt = _clock.now();
    final asked = Asked(at: _effectiveNow(state), activationId: state.activationId, seen: state.verdictAt);
    final device = await _device(_timing.machineId, state.deviceKind);
    final reports = spendsReported(await _reportable(state));
    final body = {..._validateBody(state, device), if (reports != null) 'spends': reports, 'kids': _keyIds};
    HttpResponse? response;
    try {
      response = await _post('validate', body, timeout);
    } catch (_) {
      response = null;
    }
    final judged = await _judgeFresh(state, response);
    final outcome = renewalOutcome(
      response: response,
      check: judged.check,
      askedAt: askedAt,
      now: judged.now,
      major: _major,
      key: state.key,
      keptMajor: state.keptMajor,
      kind: device.kind,
      ownClaim: device.ownClaim,
    );
    final ops = _confirmations(state, response);
    final heard = response != null && !noAnswer(response.status);
    final patch = reports != null && heard && ops.isEmpty
        ? {...outcome.patch, Field.backoffSince: askedAt, Field.backoffMs: askAgainMs}
        : outcome.patch;
    await _saveOps(state, patch, Basis(answer: asked), ops);
    if (!outcome.answered) return (answered: false, status: null);
    return (answered: true, status: _metered(outcome.status, judged.check, state, ops));
  }

  /// A licensed answer's status with the meters of the lease that brought it.
  LicenseStatus? _metered(LicenseStatus? status, LeaseCheck? check, StoredState state, List<JournalOp> ops) {
    final claims = check?.claims;
    if (status == null || claims == null) return status;
    return _meteredStatus(status, claims, landJournal(state, ops, guardedNow(_clock.now(), state.lastSeen)).state);
  }

  /// The lease a validate's 200 carried, checked on this device as of the server's time.
  Future<({LeaseCheck? check, int now})> _judgeFresh(StoredState state, HttpResponse? response) async {
    final lease = response?.status == 200 ? parseLeaseBody(response!.json).lease : null;
    if (lease == null || lease.isEmpty) return (check: null, now: _effectiveNow(state));
    final judged = await _judged(lease, state.key ?? '', state.activationId ?? '', state.deviceKind, _effectiveNow(state));
    return (check: judged.check, now: judged.now);
  }

  /// A lease the server just answered, checked for this holder as of the
  /// server's time (the clock guard brought back best-effort).
  Future<({LeaseCheck check, int now})> _judged(String lease, String key, String activationId, DeviceKind? kind, int fallbackNow) async {
    int now;
    try {
      now = await _serverNow(lease, key, activationId, (patch, guard) async {
        await _saveBestEffort(patch, guard);
      });
    } catch (_) {
      now = fallbackNow;
    }
    return (check: await _evaluate(lease, now, key: key, activationId: activationId, deviceKind: kind), now: now);
  }

  /// What a validate and a `use` send for the server's device check: every
  /// fingerprint this device answers to when it can tell, none when it cannot.
  Map<String, Object?> _deviceBody(StoredState state, Device device) => withoutNulls({
        'key': state.key,
        'activationId': state.activationId,
        'major': _major,
        if (device.canTell) 'fingerprints': device.fingerprints,
        if (device.canTell && device.kind != null) 'fingerprintKind': device.kind!.wire,
      });

  Map<String, Object?> _validateBody(StoredState state, Device device) =>
      {..._deviceBody(state, device), if (state.keptMajor != null) 'keptMajor': state.keptMajor};
}

/// The journal change an answer's confirmations make: none when it named none.
List<JournalOp> _confirmations(StoredState state, HttpResponse? response) {
  final entries = spendsConfirmed(response);
  final about = state.activationId;
  return entries.isNotEmpty && about != null ? [JournalOp.confirmed(about, entries)] : const [];
}

/// A `licensed` status from a key's lease with its meters; any other status,
/// and a lease with no meter, unchanged.
LicenseStatus _meteredStatus(LicenseStatus status, LeaseClaims claims, StoredState state) {
  if (status.state != LicenseState.licensed) return status;
  final meters = meterStatusOf(figuresFor(claims, state), state.spends);
  return meters.isEmpty ? status : status.withMeters(Map.unmodifiable(meters));
}
