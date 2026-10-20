/// The default fingerprinters: the operating system's machine id on Windows,
/// macOS and Linux, with the host name's as its alternate (section 4); the
/// Keychain install id on iOS and `ANDROID_ID` on Android, with no host name
/// at all (4.1). A read that did not finish gives NO fingerprint and is not
/// kept; a settled one is kept for the process.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'device.dart';
import 'identity.dart';
import 'keys.dart';
import 'machine_id.dart';
import 'platform_bridge.dart';
import 'system_source.dart';
import 'types.dart';

/// The desktop default: the machine id ([readMachineId]) hashed, the host
/// name's when the machine has no id to read; the host name's always offered
/// as an alternate. [get] waits as long as an activation does and throws when
/// the id still could not be read.
final class DesktopFingerprinter extends Fingerprinter {
  /// The default for this process (`source` null), or one reading `source`.
  DesktopFingerprinter({MachineIdSource? source, HostNames? Function()? host})
      : _source = source,
        _host = host ?? hostNames;

  final MachineIdSource? _source;
  final HostNames? Function() _host;
  Settled? _own;

  /// The settled fingerprint of the process's default fingerprinter.
  static Settled? _process;

  Settled? get _settled => _source == null ? _process : _own;
  set _settled(Settled? value) => _source == null ? _process = value : _own = value;

  @override
  Future<DeviceIdentity> identify(Duration timeout) async {
    final legacy = hostNamesFingerprint(_host());
    final known = _settled ?? settledOn(await readMachineId(_source ?? SystemMachineIdSource(), timeout), () => legacy);
    if (known != null) _settled = known;
    return withHostAlternate(known, legacy);
  }

  @override
  Future<String> get() async {
    final fingerprint = (await identify(activateMachineIdTimeout)).fingerprint;
    if (fingerprint == null) throw StateError('this machine\'s id could not be read in time');
    return fingerprint;
  }
}

/// The value some old Android builds share for every device: no id.
const String sharedAndroidId = '9774d56d682e549c';

/// The phone and tablet default (4.1): iOS's Keychain install id (raw
/// `machine-id|ios:<id>`) and Android's `ANDROID_ID` (raw
/// `machine-id|android:<id>`, lower case), kind `machine`, no alternate. An
/// Android device with no usable `ANDROID_ID` (none, or the one old builds
/// share) gets an install id of the SDK's own in the app's private storage,
/// raw `install-id|android:<uuid>`, of no kind, so its seats are never held to
/// the device. Anything that fails is no fingerprint this time.
final class MobileFingerprinter extends Fingerprinter {
  MobileFingerprinter({required this.product, PlatformBridge? bridge, String? system})
      : _bridge = bridge,
        _system = system ?? Platform.operatingSystem;

  final String product;
  final PlatformBridge? _bridge;
  final String _system;
  Settled? _settled;

  PlatformBridge get _channel => _bridge ?? PlatformBridge.instance;

  @override
  Future<DeviceIdentity> identify(Duration timeout) async {
    final known = _settled ?? await _read().timeout(timeout, onTimeout: () => null);
    if (known != null) _settled = known;
    return mobileIdentityOf(known);
  }

  @override
  Future<String> get() async {
    final fingerprint = (await identify(activateMachineIdTimeout)).fingerprint;
    if (fingerprint == null) throw StateError('this device\'s id could not be read');
    return fingerprint;
  }

  Future<Settled?> _read() async {
    try {
      final id = await _channel.invoke(NativeMethod.machineId, {'product': product});
      return _system == 'android' ? await _android(id) : _ios(id);
    } catch (_) {
      return null;
    }
  }

  Settled? _ios(Object? id) =>
      id is String && id.isNotEmpty ? (fingerprint: machineFingerprint('ios:$id'), kind: DeviceKind.machine) : null;

  Future<Settled?> _android(Object? id) async {
    // No answer at all is "cannot tell this time" (contract 4.1), never a device with no id.
    if (id is! String) return null;
    final lower = id.toLowerCase();
    if (lower.isNotEmpty && lower != sharedAndroidId) {
      return (fingerprint: machineFingerprint('android:$lower'), kind: DeviceKind.machine);
    }
    final installId = await _installId();
    return (fingerprint: hashFingerprint('install-id|android:$installId'), kind: null);
  }

  /// The SDK's own install id, kept in the app's support folder (private,
  /// lost with the app): made once, a random version 4 UUID.
  Future<String> _installId() => _installIdRead ??= _readInstallId().whenComplete(() => _installIdRead = null);

  /// The install id read now, one read at a time per fingerprinter.
  Future<String>? _installIdRead;

  Future<String> _readInstallId() async {
    final file = File('${await _channel.supportDirectory()}${Platform.pathSeparator}KeyGrant${Platform.pathSeparator}install-id');
    final kept = await _keptId(file);
    if (kept != null) return kept;
    await file.parent.create(recursive: true);
    // Written whole or not at all (a temp file renamed over it), then read back,
    // so a process that lost a race to write it takes the one that won.
    final temp = File('${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await temp.writeAsString(uuidV4(), flush: true);
    if (await _keptId(file) == null) {
      await temp.rename(file.path);
    } else {
      await temp.delete();
    }
    final written = await _keptId(file);
    if (written == null) throw StateError('the install id could not be kept');
    return written;
  }

  /// The install id the file holds, when it holds a whole one.
  Future<String?> _keptId(File file) async {
    if (!await file.exists()) return null;
    final kept = (await file.readAsString()).trim();
    return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(kept) ? kept : null;
  }
}

/// A random version 4 UUID, lower case, from the platform's secure random source.
String uuidV4() {
  final random = Random.secure();
  final bytes = [for (var i = 0; i < 16; i++) random.nextInt(256)];
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
