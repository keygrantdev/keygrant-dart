/// Key pickup (the SDK contract, section 13; pickup.ts): what a person typed,
/// checked before anything is sent; the server's refusals as the SDK's errors;
/// its answer read leniently; and the key a restore activates.
library;

import 'entitlements.dart';
import 'json.dart';
import 'types.dart';
import 'wire.dart';

/// What a pickup call sends for what a person typed, or the error that refuses
/// it before anything is sent (`pickupAsk`). `code` null is the ask for a code.
final class PickupAsk {
  const PickupAsk._({this.email, this.code, this.refused});
  final String? email;
  final String? code;
  final PickupError? refused;

  /// The body the call sends.
  Map<String, Object?> get send => withoutNulls({'email': email, 'code': code});

  Map<String, Object?> toJson() => refused != null ? {'refused': refused!.wire} : {'send': send};
}

PickupAsk pickupAsk(String email, String? code) {
  final entered = enteredEmail(email);
  final address = entered.send;
  if (entered.tooLong || address == null) return const PickupAsk._(refused: PickupError.invalidEmail);
  if (code == null) return PickupAsk._(email: address);
  final typed = enteredCode(code);
  final digits = typed.send;
  if (typed.malformed || digits == null) return const PickupAsk._(refused: PickupError.wrongCode);
  return PickupAsk._(email: address, code: digits);
}

/// How long the keys a confirm answered are kept in memory (never stored), for
/// a confirm or a restore with the same address and code: a code's own life
/// (ms). The first confirm spends the code, so a restore whose activation got no
/// answer, or a restore after `confirmPickUp(email, code)`, needs no new code.
const int pickupKeysKeepMs = 10 * 60000;

/// The error a refused pickup call answers, and how long to wait when the body
/// says (`retryAfter`, seconds, kept on `too-many-attempts` and `try-again`).
final class PickupRefusal {
  const PickupRefusal(this.error, [this.retryAfter]);
  final PickupError error;
  final int? retryAfter;

  Map<String, Object?> toJson() => withoutNulls({'error': error.wire, 'retryAfter': retryAfter});
}

PickupRefusal pickupRefusal(Object? json) {
  final body = json is List ? null : asObject(json);
  final error = switch (body?['error']) {
    'pickup-disabled' => PickupError.pickupDisabled,
    'wrong-code' => PickupError.wrongCode,
    'code-expired' => PickupError.codeExpired,
    'too-many-attempts' || 'rate-limited' => PickupError.tooManyAttempts,
    'try-again' || 'unavailable' => PickupError.tryAgain,
    'invalid-request' => PickupError.invalidEmail,
    _ => PickupError.network,
  };
  final waits = error == PickupError.tooManyAttempts || error == PickupError.tryAgain;
  return PickupRefusal(error, waits ? figureOf(body?['retryAfter']) : null);
}

/// The majors a picked key covers; [maxMajor] null for no top.
final class PickedVersions {
  const PickedVersions({required this.minMajor, this.maxMajor, this.upgradeUntil});
  final int minMajor;
  final int? maxMajor;

  /// The end of the key's open upgrade window (ms).
  final int? upgradeUntil;

  Map<String, Object?> toJson() => {'minMajor': minMajor, 'maxMajor': maxMajor, 'upgradeUntil': upgradeUntil};
}

/// The sale of several keys a picked key is one of.
final class PickedSale {
  const PickedSale({required this.id, required this.index, required this.size});
  final String id;
  final int index;
  final int size;

  Map<String, Object?> toJson() => {'id': id, 'index': index, 'size': size};
}

/// One key a pickup handed back: enough for the app to let the customer pick
/// one (its model, what it grants, its versions, its seats), never shown as a
/// key. Activate it with `activate(picked.key, email: ..., code: picked.activationCode)`,
/// or let `restoreByEmail` choose and activate one.
final class PickedKey {
  const PickedKey({
    required this.key,
    this.model = '',
    this.modelName,
    this.state = '',
    this.entitlements = const {},
    this.expiresAt,
    this.versions,
    this.deviceLimit = 0,
    this.activeDevices = 0,
    this.held = false,
    this.sale,
    this.activationCode,
  });

  final String key;

  /// 'perpetual', 'subscription', 'trial' or 'timed'.
  final String model;

  /// The licence model it was sold under, when it was: the name to show.
  final String? modelName;

  /// 'active' or 'trial'.
  final String state;
  final Map<String, Entitlement> entitlements;

  /// When it ends (ms); null for a key that does not.
  final int? expiresAt;

  /// The majors it covers; null for a key sold without a version (it takes the
  /// version of the first build to activate it).
  final PickedVersions? versions;
  final int deviceLimit;
  final int activeDevices;

  /// This device holds a seat on it already: activating it takes that seat back.
  final bool held;
  final PickedSale? sale;

  /// The code a user-locked key's activation takes, already proven by the pickup.
  final String? activationCode;

  Map<String, Object?> toJson() => {
        'key': key,
        'model': model,
        'modelName': modelName,
        'state': state,
        'entitlements': entitlementsJson(entitlements),
        'expiresAt': expiresAt,
        'versions': versions?.toJson(),
        'deviceLimit': deviceLimit,
        'activeDevices': activeDevices,
        'held': held,
        if (sale != null) 'sale': sale!.toJson(),
        if (activationCode != null) 'activationCode': activationCode,
      };

  /// A key as a vector or a stored answer holds it after reading (`pickedKey`).
  static PickedKey? fromJson(Object? raw) {
    final r = raw is List ? null : asObject(raw);
    final key = r?['key'];
    if (r == null || key is! String || key.isEmpty || key.length > maxKey) return null;
    final model = r['model'], modelName = r['modelName'], state = r['state'], code = r['activationCode'];
    return PickedKey(
      key: key,
      model: model is String ? model : '',
      modelName: modelName is String ? modelName : null,
      state: state is String ? state : '',
      entitlements: entitlementsOf(r['entitlements']),
      expiresAt: figureOf(r['expiresAt']),
      versions: _versionsOf(r['versions']),
      deviceLimit: figureOf(r['deviceLimit']) ?? 0,
      activeDevices: figureOf(r['activeDevices']) ?? 0,
      held: r['held'] == true,
      sale: _saleOf(r['sale']),
      activationCode: code is String && RegExp(r'^[0-9]{6}$').hasMatch(code) ? code : null,
    );
  }
}

PickedVersions? _versionsOf(Object? raw) {
  final v = raw is List ? null : asObject(raw);
  final minMajor = figureOf(v?['minMajor']);
  if (v == null || minMajor == null) return null;
  return PickedVersions(minMajor: minMajor, maxMajor: figureOf(v['maxMajor']), upgradeUntil: figureOf(v['upgradeUntil']));
}

PickedSale? _saleOf(Object? raw) {
  final s = raw is List ? null : asObject(raw);
  final id = s?['id'], index = figureOf(s?['index']), size = figureOf(s?['size']);
  if (id is! String || index == null || index < 1 || size == null || size < 1) return null;
  return PickedSale(id: id, index: index, size: size);
}

/// The keys a confirm's 200 answers, read leniently, in order; null when the
/// body is not a pickup answer (not an object, or `keys` not a list).
List<PickedKey>? pickedKeysOf(Object? json) {
  final keys = (json is List ? null : asObject(json))?['keys'];
  if (keys is! List) return null;
  return [for (final raw in keys) if (PickedKey.fromJson(raw) case final picked?) picked];
}

/// Whether a key covers the build's `major` at `now` (the device clock, ms).
bool covers(PickedVersions? versions, int major, int now) {
  if (versions == null) return true;
  if (major < versions.minMajor) return false;
  final max = versions.maxMajor, until = versions.upgradeUntil;
  return max == null || major <= max || (until != null && until > now);
}

/// The key `restoreByEmail` activates, by its place in `keys`, or why none
/// (`no-key`, `upgrade`, `outdated`): of the keys that cover the build, the
/// first held, else the first with a free seat, else the first.
final class ChosenKey {
  const ChosenKey._(this.index, this.refused);
  final int? index;
  final RestoreError? refused;

  Map<String, Object?> toJson() => refused != null ? {'refused': refused!.wire} : {'index': index};
}

ChosenKey chosenKey(List<PickedKey> keys, int major, int now) {
  if (keys.isEmpty) return const ChosenKey._(null, RestoreError.noKey);
  final covering = [for (var i = 0; i < keys.length; i++) if (covers(keys[i].versions, major, now)) i];
  int? first(bool Function(PickedKey k) test) {
    for (final i in covering) {
      if (test(keys[i])) return i;
    }
    return null;
  }

  final pick = first((k) => k.held) ?? first((k) => k.activeDevices < k.deviceLimit) ?? first((_) => true);
  if (pick != null) return ChosenKey._(pick, null);
  final older = keys.any((k) => k.versions != null && k.versions!.minMajor <= major);
  return ChosenKey._(null, older ? RestoreError.upgrade : RestoreError.outdated);
}
