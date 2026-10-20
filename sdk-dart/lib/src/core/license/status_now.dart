part of 'license.dart';

/// How `status()` answers from what is stored, asking the server when it
/// should (license.ts `statusNow`, 5.2).
abstract class _StatusEngine extends _PickupEngine {
  _StatusEngine(super.config, super.timing);

  @override
  Future<LeaseClaims?> _keyClaims(StoredState state) async {
    final status = await _statusNow(state, false, true);
    final lease = state.lease;
    if (status.state != LicenseState.licensed || status.source == LicenseSource.file || lease == null || lease.isEmpty) {
      return null;
    }
    final check = await _evaluate(lease, _effectiveNow(state),
        key: state.key, activationId: state.activationId, deviceKind: state.deviceKind);
    return check.claims;
  }

  /// The status from what is stored only, with no ask and no write.
  Future<LicenseStatus> _storedStatus() async {
    final state = await _loadForStatus(true);
    return state == null ? _unreadable : _statusNow(state, false, true);
  }

  /// The status, asking the server when it should; `readOnly`: from what is
  /// stored only, with no ask and no write.
  Future<LicenseStatus> _statusNow(StoredState state, bool forceOnline, bool readOnly) async {
    final file = await _fileStatus(state);
    if (file?.state == LicenseState.licensed) return file!;
    final now = _effectiveNow(state);
    final key = state.key;
    final hasKey = key != null && key.isNotEmpty;
    Device? device;
    if (state.refused == Refusal.device) device = await _device(_timing.machineId, state.deviceKind);
    final refused = hasKey ? standingRefusal(state, _major, ownClaim: device?.ownClaim, canTell: device?.canTell ?? false) : null;
    if (refused != null && readOnly) return LicenseStatus(LicenseState.invalid, reason: refused.reason, key: key);
    if (refused != null) return _refusedStatus(state, refused, forceOnline);
    final lease = state.lease;
    if (hasKey && lease != null && lease.isNotEmpty) return _licenseStatus(state, lease, now, forceOnline, readOnly);
    return _trialOrFile(state, now, file, forceOnline, readOnly);
  }

  /// With no key to answer: a running trial, else a stored file that does not
  /// license this build, else the trial that has ended, else `unlicensed`.
  Future<LicenseStatus> _trialOrFile(StoredState state, int now, LicenseStatus? file, bool forceOnline, bool readOnly) async {
    final trial = state.trialStart != null ? await _trialStatus(state, now, forceOnline: forceOnline, readOnly: readOnly) : null;
    if (trial?.state == LicenseState.trial) return trial!;
    return file ?? trial ?? const LicenseStatus(LicenseState.unlicensed);
  }

  /// A refusal that stands: answered as stored, asked again once its wait is over.
  Future<LicenseStatus> _refusedStatus(StoredState state, Refusal refused, bool force) async {
    final stored = LicenseStatus(LicenseState.invalid, reason: refused.reason, key: state.key);
    if (!askDue(state, _clock.now(), force)) return stored;
    return await _tryRenew(state) ?? stored;
  }

  Future<LicenseStatus> _licenseStatus(StoredState state, String lease, int now, bool forceOnline, bool readOnly) async {
    final evaluated = await _evaluate(lease, now, key: state.key, activationId: state.activationId, deviceKind: state.deviceKind);
    final claims = evaluated.claims;
    final plain = leaseStatus(evaluated, state.key);
    if (claims == null) {
      // Not licensed here: give the server a chance to heal it, once the wait allows.
      final renewed = !readOnly && askDue(state, _clock.now(), forceOnline) ? await _tryRenew(state) : null;
      return renewed ?? plain;
    }
    final offline = _meteredStatus(plain, claims, state);
    return readOnly ? offline : _licensedNow(state, claims, offline, now, forceOnline);
  }

  /// A lease that licenses this build: this run noted (`keptMajor`), then
  /// asked online when forced, or, bounded, when the server should hear from
  /// this device and the wait allows.
  Future<LicenseStatus> _licensedNow(StoredState state, LeaseClaims claims, LicenseStatus offline, int now, bool forceOnline) async {
    final held = await _noteKept(state, claims, now);
    if (forceOnline) return await _tryRenew(held) ?? offline;
    final journal = await _reportable(held);
    final view = held.patched({Field.spends: [for (final e in journal) e.toJson()]});
    final asks = asksOnValidLease(claims: claims, state: view, major: _major, now: now, clockNow: _clock.now());
    if (!asks) return offline;
    return await _tryRenew(held, _timing.statusCheck) ?? offline;
  }

  /// The state with this run noted in `keptMajor`, persisted when that changed.
  Future<StoredState> _noteKept(StoredState state, LeaseClaims claims, int now) async {
    final keptMajor = keptWith(state.keptMajor, claims, now, _major);
    if (keptMajor == state.keptMajor) return state;
    await _saveBestEffort({Field.keptMajor: keptMajor}, null, Basis.about(state.activationId));
    return state.patched({Field.keptMajor: keptMajor});
  }
}
