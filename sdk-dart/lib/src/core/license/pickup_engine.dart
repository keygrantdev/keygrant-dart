part of 'license.dart';

/// Key pickup (pickup-engine.ts; the SDK contract, section 13): a code mailed
/// to the address a key was sold to, that address's keys for the code, and a
/// restore that confirms and activates the key that fits this build.
abstract class _PickupEngine extends _SeatEngine {
  _PickupEngine(super.config, super.timing);

  /// The keys the last confirm answered, by the address and code as sent, in
  /// memory only, for [pickupKeysKeepMs].
  ({String email, String code, List<PickedKey> keys, int at})? _confirmed;

  /// Ask KeyGrant to mail a code to `email`. Writes nothing; never throws.
  Future<PickUpSendResult> _requestPickup(String email) async {
    final ask = pickupAsk(email, null);
    if (ask.refused != null) return PickUpSendFailed(ask.refused!);
    final HttpResponse res;
    try {
      res = await _post('pickup', ask.send);
    } catch (_) {
      return const PickUpSendFailed(PickupError.network);
    }
    if (res.status == 200) return const PickUpCodeSent();
    final refusal = pickupRefusal(res.json);
    return PickUpSendFailed(refusal.error, refusal.retryAfter);
  }

  /// The address's keys for the code, each marked `held` when this device
  /// holds a seat on it. Writes nothing; never throws.
  Future<PickUpKeysResult> _confirmPickup(String email, String code) async {
    final ask = pickupAsk(email, code);
    if (ask.refused != null) return PickUpKeysFailed(ask.refused!);
    final kept = _keptKeys(ask.email!, ask.code!);
    if (kept != null) return PickUpKeysFound(kept);
    // Read-only: this runs outside the one-at-a-time order, beside any call.
    StoredState stored;
    try {
      stored = await _load(true);
    } catch (_) {
      stored = StoredState.empty;
    }
    final device = await _device(_timing.machineId, _installKind(stored.deviceKind));
    final HttpResponse res;
    try {
      res = await _post('pickup/confirm', {...ask.send, if (device.canTell) 'fingerprints': device.fingerprints});
    } catch (_) {
      return const PickUpKeysFailed(PickupError.network);
    }
    if (res.status != 200) {
      final refusal = pickupRefusal(res.json);
      return PickUpKeysFailed(refusal.error, refusal.retryAfter);
    }
    final keys = pickedKeysOf(res.json);
    if (keys == null) return const PickUpKeysFailed(PickupError.network);
    _confirmed = (email: ask.email!, code: ask.code!, keys: List.unmodifiable(keys), at: _clock.now());
    return PickUpKeysFound(List.unmodifiable(keys));
  }

  /// The keys a confirm with this address and code answered, while they are kept.
  List<PickedKey>? _keptKeys(String email, String code) {
    final c = _confirmed;
    if (c == null) return null;
    final age = _clock.now() - c.at;
    return c.email == email && c.code == code && age >= 0 && age < pickupKeysKeepMs ? c.keys : null;
  }

  /// Confirm the code and activate the key that fits this build, with the
  /// address it was picked up with and, for a code-locked key, the code the
  /// pickup handed back.
  Future<RestoreResult> _restoreNow(String email, String code) async {
    final picked = await _confirmPickup(email, code);
    final List<PickedKey> keys;
    switch (picked) {
      case PickUpKeysFailed(:final error, :final retryAfter):
        return RestoreFailed(RestoreError.fromPickup(error), retryAfter);
      case PickUpKeysFound(keys: final found):
        keys = found;
    }
    final choice = chosenKey(keys, _major, _clock.now());
    if (choice.refused != null) return RestoreFailed(choice.refused!);
    final key = keys[choice.index!];
    final address = pickupAsk(email, null).email ?? email;
    final activated = await _activateNow(key.key, email: address, code: key.activationCode);
    switch (activated) {
      case Activated():
        // Activated: the keys (and a lock's single-use code among them) are done with.
        _confirmed = null;
        return const Restored();
      case ActivateFailed(:final error):
        return RestoreFailed(RestoreError.fromActivation(error));
    }
  }
}
