/// How the pure-Dart core reaches the plugin's native code (Swift on iOS and
/// macOS, Kotlin on Android) and the Flutter-only pieces, without importing
/// Flutter: the plugin sets [PlatformBridge.instance] when the app starts.
library;

/// There is no plugin channel here: a pure Dart run, a test, or an isolate
/// the plugin was not registered in. Every read that needs one falls back.
final class NoPlatformChannel implements Exception {
  const NoPlatformChannel();
  @override
  String toString() => 'NoPlatformChannel: the KeyGrant plugin is not registered in this isolate';
}

/// What the core asks of the platform.
abstract class PlatformBridge {
  const PlatformBridge();

  /// The bridge in use: the plugin's once Flutter has registered it
  /// (`KeyGrantPlugin.registerWith`), else one with no channel.
  static PlatformBridge instance = const NoPlatformBridge();

  /// Call the plugin's native method `method`. Throws [NoPlatformChannel] when
  /// there is no channel, and anything else when the native side failed.
  Future<Object?> invoke(String method, [Map<String, Object?> arguments = const {}]);

  /// The app's own support folder (`path_provider`'s
  /// `getApplicationSupportDirectory()`). Throws [NoPlatformChannel] when it
  /// cannot be asked.
  Future<String> supportDirectory();
}

/// The bridge with no channel.
final class NoPlatformBridge extends PlatformBridge {
  const NoPlatformBridge();

  @override
  Future<Object?> invoke(String method, [Map<String, Object?> arguments = const {}]) async =>
      throw const NoPlatformChannel();

  @override
  Future<String> supportDirectory() async => throw const NoPlatformChannel();
}

/// The native methods: the machine id on macOS (`IOPlatformUUID` through
/// IOKit), the Keychain install id on iOS, `ANDROID_ID` on Android; and the
/// iOS Keychain trial stash.
abstract final class NativeMethod {
  static const machineId = 'machineId';
  static const readTrialStart = 'readTrialStart';
  static const writeTrialStart = 'writeTrialStart';
}

/// The channel's name.
const String keygrantChannel = 'dev.keygrant/keygrant';
