/// Who this device is (the SDK contract, section 4; device.ts): as far as can
/// be told this call, and never guessed.
library;

import 'dart:async';

import 'keys.dart';
import 'types.dart';

/// What a fingerprinter says of this device: its fingerprint (null when it
/// cannot be told this time), what it hashes ([kind], null when unknown), and
/// the other fingerprints this device answers to.
final class DeviceIdentity {
  const DeviceIdentity({required this.fingerprint, this.kind, this.alternates = const []});

  final String? fingerprint;
  final DeviceKind? kind;
  final List<String> alternates;

  Map<String, Object?> toJson() => {
        'fingerprint': fingerprint,
        if (kind != null) 'kind': kind!.wire,
        'alternates': alternates,
      };
}

/// Who this device is, for holding a lease to it and telling the server.
final class Device {
  const Device({
    required this.own,
    this.kind,
    required this.canTell,
    required this.fingerprints,
    required this.claims,
    this.ownClaim,
    required this.hostname,
  });

  /// This run's own fingerprint, or null when it cannot be told this time.
  final String? own;

  /// What [own] hashes; null when the fingerprinter does not say, or with no [own].
  final DeviceKind? kind;
  final bool canTell;

  /// Every fingerprint this device answers to: its own first, then its alternates.
  final List<String> fingerprints;

  /// Their `fp` claims.
  final List<String> claims;

  /// The claim of [own] alone, when there is one.
  final String? ownClaim;

  /// The host-name fingerprint to activate under when the machine id cannot be read.
  final String? hostname;

  Map<String, Object?> toJson() => {
        'own': own,
        if (kind != null) 'kind': kind!.wire,
        'canTell': canTell,
        'fingerprints': fingerprints,
        'claims': claims,
        if (ownClaim != null) 'ownClaim': ownClaim,
        'hostname': hostname,
      };
}

/// Who this device is ([Device]) from what its fingerprinter said this time,
/// on an install keyed as `installKind`, held to its device or not
/// (`deviceHold`). Install memory: once a machine id has keyed this install, a
/// host-name answer is "cannot tell". Not held, a device has no kind and is
/// judged as a run that cannot tell; its own fingerprint still activates.
Device deviceFrom(
  DeviceIdentity identity,
  DeviceKind? installKind,
  bool deviceHold, [
  String Function(String fingerprint) claimOf = fingerprintClaim,
]) {
  final keyedAs = deviceHold ? installKind : null;
  // A kind with no fingerprint says nothing.
  final read = identity.fingerprint == null ? null : identity.kind;
  final own = read == DeviceKind.hostname && keyedAs == DeviceKind.machine ? null : identity.fingerprint;
  final fingerprints = [if (own != null) own, ...identity.alternates.where((f) => f != own)];
  final hostname = read == DeviceKind.hostname
      ? identity.fingerprint
      : (identity.alternates.isEmpty ? null : identity.alternates.first);
  final claims = [for (final f in fingerprints) claimOf(f)];
  final mine = deviceHold && own != null;
  return Device(
    own: own,
    kind: mine ? read : null,
    canTell: deviceHold && own != null,
    fingerprints: fingerprints,
    claims: claims,
    ownClaim: mine ? claims.first : null,
    hostname: hostname,
  );
}

/// A fingerprinter: what identifies this device. [get] alone says nothing of
/// what the fingerprint hashes, so its seats are never held to their device;
/// implement [identify] and report [DeviceKind.machine] for a stable machine
/// id that should be.
abstract class Fingerprinter {
  const Fingerprinter();

  /// This device's fingerprint. A throw, or no answer in time, is read as
  /// "cannot tell this time".
  Future<String> get();

  /// Optional, and what the SDK uses when it answers: this device's
  /// fingerprint (null when it cannot be read this time), what it hashes, and
  /// the other fingerprints it has been activated under. Null (the default)
  /// means this fingerprinter has only [get].
  Future<DeviceIdentity>? identify(Duration timeout) => null;
}

/// Reads, and once settled keeps, who this device is.
final class DeviceIdentityReader {
  DeviceIdentityReader(this._fingerprinter, {this.slack = const Duration(seconds: 1)});

  final Fingerprinter _fingerprinter;

  /// How much longer than its own bound [Fingerprinter.identify] is given.
  final Duration slack;
  DeviceIdentity? _known;
  final Map<String, String> _claims = {};

  /// Who this device is ([deviceFrom]), reading for at most about `timeout`. A
  /// fingerprinter that throws, or does not answer in time, gives "cannot
  /// tell", not kept.
  Future<Device> read(Duration timeout, DeviceKind? installKind, bool deviceHold) async {
    final identity = _known ?? await _identity(timeout);
    if (identity.fingerprint != null) _known = identity;
    return deviceFrom(identity, installKind, deviceHold, _claimOf);
  }

  String _claimOf(String fingerprint) => _claims.putIfAbsent(fingerprint, () => fingerprintClaim(fingerprint));

  Future<DeviceIdentity> _identity(Duration timeout) async {
    try {
      final identify = _fingerprinter.identify(timeout);
      if (identify != null) return await identify.timeout(timeout + slack);
      return DeviceIdentity(fingerprint: await _fingerprinter.get().timeout(timeout));
    } catch (_) {
      return const DeviceIdentity(fingerprint: null);
    }
  }
}

/// The fingerprint an activation is made under, and what it hashes; or null,
/// which an activation answers `network`: the device's own; when that cannot
/// be told, the host name, but not on an install keyed by a machine id, and not
/// with no host-name alternate.
({String fingerprint, DeviceKind? kind})? activationIdentity(Device device, DeviceKind? installKind) {
  final own = device.own;
  if (own != null) return (fingerprint: own, kind: device.kind);
  final hostname = device.hostname;
  if (installKind == DeviceKind.machine || hostname == null) return null;
  return (fingerprint: hostname, kind: DeviceKind.hostname);
}
