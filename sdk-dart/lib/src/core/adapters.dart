/// The adapters all platform I/O lives behind (the SDK contract, section 8),
/// and how a licence is set up.
library;

import 'device.dart';
import 'http.dart';
import 'stored_state.dart';

/// Where the stored state lives.
abstract class StorageAdapter {
  const StorageAdapter();

  /// The stored state, or null for none. `readOnly` (a call behind one that
  /// has not finished): read and write nothing, not even to repair. Throws
  /// when it cannot be read just now.
  Future<StoredState?> read({bool readOnly = false});

  /// Save a whole state.
  Future<void> write(StoredState state);

  /// Save `merge` of the state as stored at the moment of saving. The default
  /// is read, merge, write; the default file storage merges again onto a newer
  /// state another process saved in between.
  Future<void> update(StoredState Function(StoredState latest) merge) async {
    await write(merge(await read() ?? StoredState.empty));
  }
}

/// A trial's start kept where it outlives the app (the Windows registry, the
/// iOS Keychain), so a reinstall does not restart a trial. Either call may
/// throw; neither ever costs the customer anything.
abstract interface class RegistryStash {
  Future<int?> readTrialStart();
  Future<void> writeTrialStart(int ms);
}

/// The stash that keeps nothing: the default where no platform stash applies.
final class NoRegistryStash implements RegistryStash {
  const NoRegistryStash();
  @override
  Future<int?> readTrialStart() async => null;
  @override
  Future<void> writeTrialStart(int ms) async {}
}

/// The device clock, in milliseconds since the epoch.
abstract interface class LicenseClock {
  int now();
}

/// The system clock.
final class SystemClock implements LicenseClock {
  const SystemClock();
  @override
  int now() => DateTime.now().millisecondsSinceEpoch;
}

/// Adapter overrides; any left null uses the default.
final class LicenseAdapters {
  const LicenseAdapters({this.storage, this.registry, this.clock, this.fingerprinter, this.http});

  final StorageAdapter? storage;
  final RegistryStash? registry;
  final LicenseClock? clock;
  final Fingerprinter? fingerprinter;
  final HttpAdapter? http;
}

/// How a licence is set up.
final class LicenseConfig {
  const LicenseConfig({
    required this.product,
    required this.apiBaseUrl,
    this.publicJwks,
    this.publicJwk,
    this.major = 1,
    this.deviceName,
    this.deviceHold = true,
    this.httpTimeout = defaultHttpTimeout,
    this.revokedLicenseFiles = const [],
    this.adapters = const LicenseAdapters(),
  });

  /// The product slug, matching the KeyGrant product.
  final String product;

  /// The KeyGrant API base, e.g. `https://api.keygrant.dev`.
  final String apiBaseUrl;

  /// The product's public keys (JWKs), embedded at build time: the key that
  /// signs its leases, and the next one once the product has one staged (the
  /// `keys` of `GET /v1/products/<product>/pubkey`; [parseJwkSet] reads that
  /// answer's text). Give this or [publicJwk].
  final List<Map<String, Object?>>? publicJwks;

  /// One public key (JWK): a key set of one. Give this or [publicJwks].
  final Map<String, Object?>? publicJwk;

  /// The running app's major version. Read as the server reads a version: a
  /// 0.x build (0) runs as major 1, and so does anything below it.
  final int major;

  /// A human device name reported to the server (cut to 120 UTF-16 units).
  final String? deviceName;

  /// Whether a licence is held to the device it was activated on. False for a
  /// product on non-persistent, pooled VDI: no kind is then reported for its
  /// fingerprint, no lease is judged by its device, and the server is told no
  /// fingerprints to check. The device limit still counts seats.
  final bool deviceHold;

  /// How long a request may take before the SDK abandons it, for every call
  /// that names no shorter bound of its own.
  final Duration httpTimeout;

  /// The ids of licence files this build refuses (a file's `fid`), matched exactly.
  final List<String> revokedLicenseFiles;

  /// Adapter overrides.
  final LicenseAdapters adapters;
}
