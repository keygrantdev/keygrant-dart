/// What the default fingerprinter answers for a reading of the machine id
/// (the SDK contract, section 4 and 4.1; adapters.ts `identityOf`), and the
/// fingerprints it composes, the same in every SDK.
library;

import 'device.dart';
import 'keys.dart';
import 'machine_id.dart';
import 'types.dart';

/// What is hashed when not even the host name can be read.
const String unknownHost = 'unknown-host';

/// What a host-name fingerprint hashes, as Node names them.
final class HostNames {
  const HostNames({required this.host, required this.platform, required this.arch});

  final String host;

  /// `win32`, `darwin` or `linux`.
  final String platform;

  /// `x64`, `arm64`, `ia32` or `arm`.
  final String arch;
}

/// The host-name fingerprint of these names: every SDK composes it the same
/// way, so a machine is one device whichever reads it.
String hostFingerprint(String host, String platform, String arch) => hashFingerprint('$host|$platform|$arch');

/// The host-name fingerprint of `names`, or [unknownHost]'s when they could not be read.
String hostNamesFingerprint(HostNames? names) =>
    names == null ? hashFingerprint(unknownHost) : hostFingerprint(names.host, names.platform, names.arch);

/// The fingerprint of a machine id as `readMachineId` gives it.
String machineFingerprint(String id) => hashFingerprint('machine-id|$id');

/// A settled fingerprint and what it hashes; [kind] null for one of no kind.
typedef Settled = ({String fingerprint, DeviceKind? kind});

/// What a reading of the machine id settles on: its fingerprint; the host
/// name's when there is no id to read; null when the read did not finish.
Settled? settledOn(MachineIdReading reading, String Function() hostFp) => switch (reading) {
      MachineIdFound(:final id) => (fingerprint: machineFingerprint(id), kind: DeviceKind.machine),
      MachineIdUnavailable() => (fingerprint: hostFp(), kind: DeviceKind.hostname),
      MachineIdTransient() => null,
    };

/// Who a settled fingerprint is (null: none this time), with the host name's
/// (`legacy`) as an alternate when it is another.
DeviceIdentity withHostAlternate(Settled? known, String legacy) {
  if (known == null) return DeviceIdentity(fingerprint: null, alternates: [legacy]);
  return DeviceIdentity(
    fingerprint: known.fingerprint,
    kind: known.kind,
    alternates: known.fingerprint == legacy ? const [] : [legacy],
  );
}

/// Who this device is on Windows, macOS and Linux (`identityOf`, section 4):
/// `id` the machine id's fingerprint with the host name's as an alternate;
/// `unavailable` the host name's, no alternate; `transient` none this time,
/// the host name's as the alternate.
DeviceIdentity identityOf(MachineIdReading reading, HostNames? host) {
  final legacy = hostNamesFingerprint(host);
  return withHostAlternate(settledOn(reading, () => legacy), legacy);
}

/// Who this device is on iOS, iPadOS and Android (section 4.1): an id is its
/// fingerprint with no alternate; anything else is no fingerprint and no
/// alternate. A phone has no host name worth the name.
DeviceIdentity mobileIdentityOf(Settled? settled) => settled == null
    ? const DeviceIdentity(fingerprint: null)
    : DeviceIdentity(fingerprint: settled.fingerprint, kind: settled.kind);
