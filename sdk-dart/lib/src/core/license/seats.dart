part of 'license.dart';

/// The seat machinery (seats.ts): taking a seat on a key and releasing it. The
/// journal of unsynced spends belongs to the seat.
abstract class _SeatEngine extends _MeterEngine {
  _SeatEngine(super.config, super.timing) : _deviceName = trimToLength(config.deviceName, maxDeviceName);

  /// The device name an activation reports, cut to what the server takes.
  final String? _deviceName;

  Future<ActivateResult> _activateNow(String key, {String? email, String? code}) async {
    final entered = enteredKey(key);
    if (entered == null) return const ActivateFailed(LicenseError.invalidKey);
    final typed = typedFor(email: email, code: code);
    if (typed.refused != null) return ActivateFailed(typed.refused!);
    // Install memory protects the seat this install holds: re-activating that
    // key keeps to it; a first activation, or another key's, starts afresh.
    final stored = await _load();
    final storedKey = stored.key;
    final sameSeat = storedKey != null && sameKey(storedKey, entered);
    final installKind = sameSeat ? _installKind(stored.deviceKind) : null;
    final identity = activationIdentity(await _device(_timing.activateMachineId, installKind), installKind);
    if (identity == null) return const ActivateFailed(LicenseError.network);
    final askedAt = _effectiveNow(stored);
    final body = withoutNulls({
      'key': entered,
      'fingerprint': identity.fingerprint,
      'fingerprintKind': identity.kind?.wire,
      'name': _deviceName,
      'major': _major,
      'kids': _keyIds,
      ...typed.send,
    });
    final HttpResponse res;
    try {
      res = await _post('activate', body);
    } catch (_) {
      return const ActivateFailed(LicenseError.network);
    }
    if (res.status != 200) return ActivateFailed(mapServerError(errorOf(res.json)));
    final (:lease, :activationId) = parseLeaseBody(res.json);
    if (lease == null || lease.isEmpty || activationId == null || activationId.isEmpty) {
      return const ActivateFailed(LicenseError.network);
    }
    final now = await _serverNow(lease, entered, activationId);
    final evaluated = await _evaluate(lease, now, key: entered, activationId: activationId, deviceKind: identity.kind);
    final claims = evaluated.claims;
    if (claims == null) return const ActivateFailed(LicenseError.invalidLease);
    final patch = activationPatch(
        key: entered, activationId: activationId, lease: lease, claims: claims, now: now, major: _major, kind: identity.kind);
    // Activating another seat drops the journal of the old one, unreported; the same seat keeps it.
    final basis = Basis(activation: Asked(at: askedAt, activationId: activationId, seen: stored.verdictAt));
    await _saveWith(patch, null, basis, [JournalOp.activated(activationId)]);
    return const Activated();
  }

  Future<DeactivateResult> _deactivateNow() async {
    // What this process could not save lands first, so the release reports it.
    await _saveUnsavedJournal();
    final state = await _load();
    var released = true;
    if ((state.key ?? '').isNotEmpty && (state.activationId ?? '').isNotEmpty) {
      final device = await _device(_timing.machineId, state.deviceKind);
      if (!await _seatElsewhere(state, device)) released = await _release(state, device);
    }
    await _saveWith({...unkeyed, Field.verdictAt: _effectiveNow(state)}, null, const Basis(), const [JournalOp.deactivated()]);
    return DeactivateResult(released: released);
  }

  /// The release request, carrying the journal and, with it, the device's
  /// fingerprints. Only a 200 says the seat is free.
  Future<bool> _release(StoredState state, Device device) async {
    final reports = spendsReported(await _reportable(state));
    final body = withoutNulls({
      'key': state.key,
      'activationId': state.activationId,
      if (reports != null) 'spends': reports,
      if (reports != null && device.canTell) 'fingerprints': device.fingerprints,
    });
    try {
      return (await _post('deactivate', body)).status == 200;
    } catch (_) {
      return false;
    }
  }

  /// Whether the stored activation is another device's: a device refusal
  /// that stands for this one, or a lease held to a machine id this device
  /// does not have, expired or not.
  Future<bool> _seatElsewhere(StoredState state, Device device) async {
    final refusal = standingRefusal(state, _major, ownClaim: device.ownClaim, canTell: device.canTell);
    if (refusal == Refusal.device) return true;
    final lease = state.lease;
    return lease != null && lease.isNotEmpty && heldElsewhere(await _verify(lease, _effectiveNow(state)), device);
  }
}
