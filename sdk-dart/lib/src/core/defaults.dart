/// The adapters a licence uses where the app gives none, per platform.
library;

import 'dart:io';

import 'adapters.dart';
import 'device.dart';
import 'fingerprinters.dart';
import 'platform_bridge.dart';
import 'storage.dart';
import 'system_source.dart';

/// Whether this process runs on a phone or a tablet.
bool get isMobile => Platform.isIOS || Platform.isAndroid;

/// The default storage: section 6's folder on Windows, macOS and Linux; on
/// iOS and Android the app's support folder, `KeyGrant/<product>.json`.
StorageAdapter defaultStorage(String product) {
  if (isMobile) {
    return FileStorage(() async {
      final sep = Platform.pathSeparator;
      return '${await PlatformBridge.instance.supportDirectory()}${sep}KeyGrant$sep$product.json';
    });
  }
  return FileStorage(() async => defaultStoragePath(
        product,
        platform: nodePlatform(),
        home: _home(),
        env: Platform.environment,
      ));
}

String _home() =>
    Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? Directory.current.path;

/// The default fingerprinter: the machine id on a desktop, 4.1's on a phone.
Fingerprinter defaultFingerprinter(String product) =>
    isMobile ? MobileFingerprinter(product: product) : DesktopFingerprinter();

/// The default registry stash: the Keychain on iOS and iPadOS (4.1), none elsewhere.
RegistryStash defaultRegistry(String product) => Platform.isIOS ? KeychainTrialStash(product) : const NoRegistryStash();

/// A trial's start kept in the iOS Keychain (service `dev.keygrant.trial`,
/// account the product slug), which outlives the app, through the plugin.
final class KeychainTrialStash implements RegistryStash {
  KeychainTrialStash(this.product, {PlatformBridge? bridge}) : _bridge = bridge;

  final String product;
  final PlatformBridge? _bridge;

  PlatformBridge get _channel => _bridge ?? PlatformBridge.instance;

  @override
  Future<int?> readTrialStart() async {
    final start = await _channel.invoke(NativeMethod.readTrialStart, {'product': product});
    return start is int && start > 0 ? start : null;
  }

  @override
  Future<void> writeTrialStart(int ms) => _channel.invoke(NativeMethod.writeTrialStart, {'product': product, 'start': ms});
}
