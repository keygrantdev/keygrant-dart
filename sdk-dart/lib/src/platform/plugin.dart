/// The plugin's Flutter side: the method channel to its native code (Swift on
/// iOS and macOS, Kotlin on Android) and the app's support folder, set as the
/// core's [PlatformBridge] when Flutter registers the plugin at app start.
library;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/platform_bridge.dart';

/// The bridge over the plugin's method channel.
final class MethodChannelBridge extends PlatformBridge {
  MethodChannelBridge([MethodChannel? channel]) : _channel = channel ?? const MethodChannel(keygrantChannel);

  final MethodChannel _channel;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?> arguments = const {}]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      throw const NoPlatformChannel();
    }
  }

  @override
  Future<String> supportDirectory() async {
    try {
      return (await getApplicationSupportDirectory()).path;
    } on MissingPluginException {
      throw const NoPlatformChannel();
    }
  }
}

/// Registers the plugin's Dart side: Flutter calls [registerWith] for every
/// platform when the app starts (the plugin's `dartPluginClass`). An isolate
/// the app starts itself calls `DartPluginRegistrant.ensureInitialized()` first.
final class KeyGrantPlugin {
  KeyGrantPlugin._();

  static void registerWith() {
    PlatformBridge.instance = MethodChannelBridge();
  }
}
