// The Dart side of the plugin's method channel (lib/src/platform/plugin.dart)
// with the native side mocked: what each method sends, what a missing plugin
// and a native failure become, and the plugin's registration.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/machine_id.dart';
import 'package:keygrant/src/core/platform_bridge.dart';
import 'package:keygrant/src/core/system_source.dart';
import 'package:keygrant/src/platform/plugin.dart';

import '../support/adapters_support.dart' show fp, macUuid;

const _channel = MethodChannel(keygrantChannel);
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

/// The native side: every call recorded, each answered by `answer`.
List<MethodCall> _native(Object? Function(MethodCall call) answer, [MethodChannel channel = _channel]) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return answer(call);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final before = PlatformBridge.instance;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(_pathProvider, null);
    PlatformBridge.instance = before;
  });

  test("the channel's name is the one the native sides register", () {
    expect(keygrantChannel, 'dev.keygrant/keygrant');
    expect((NativeMethod.machineId, NativeMethod.readTrialStart, NativeMethod.writeTrialStart),
        ('machineId', 'readTrialStart', 'writeTrialStart'));
  });

  test('invoke passes the method and its arguments, and answers what the native side does', () async {
    final calls = _native((_) => 'answered');
    expect(await MethodChannelBridge().invoke('machineId', {'product': 'sluice'}), 'answered');
    expect(calls.single.method, 'machineId');
    expect(calls.single.arguments, {'product': 'sluice'});
  });

  test('invoke sends an empty map when given no arguments', () async {
    final calls = _native((_) => null);
    expect(await MethodChannelBridge().invoke('machineId'), isNull);
    expect(calls.single.arguments, <Object?, Object?>{});
  });

  test('a plugin not registered here is no channel', () async {
    await expectLater(MethodChannelBridge().invoke('machineId'), throwsA(isA<NoPlatformChannel>()));
    _native((_) => throw MissingPluginException('no such method'));
    await expectLater(MethodChannelBridge().invoke('machineId'), throwsA(isA<NoPlatformChannel>()));
  });

  test('a native failure propagates as itself', () async {
    _native((_) => throw PlatformException(code: 'keychain', message: 'locked'));
    await expectLater(
        MethodChannelBridge().invoke('readTrialStart'), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'keychain')));
  });

  test("the support folder is path_provider's application support folder", () async {
    final calls = _native((_) => '/data/app/support', _pathProvider);
    expect(await MethodChannelBridge().supportDirectory(), '/data/app/support');
    expect(calls.single.method, 'getApplicationSupportDirectory');
  });

  test('the support folder with no path_provider here is no channel', () async {
    await expectLater(MethodChannelBridge().supportDirectory(), throwsA(isA<NoPlatformChannel>()));
  });

  test('registering the plugin sets the core bridge to the channel', () async {
    expect(PlatformBridge.instance, isA<NoPlatformBridge>());
    KeyGrantPlugin.registerWith();
    expect(PlatformBridge.instance, isA<MethodChannelBridge>());
    _native((_) => 'via the plugin');
    expect(await PlatformBridge.instance.invoke('machineId'), 'via the plugin');
  });

  test("the plugin's pubspec has Flutter register its Dart side on every platform", () {
    final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
    for (final platform in ['android', 'ios', 'linux', 'macos', 'windows']) {
      final block = RegExp('\n      $platform:\n((?:        .*\n)+)').firstMatch(pubspec)?.group(1);
      expect(block, contains('dartPluginClass: KeyGrantPlugin'), reason: platform);
    }
  });

  group('IOKit on macOS through the channel', () {
    test('is the id the plugin answers', () async {
      final calls = _native((_) => macUuid);
      expect(await SystemMachineIdSource(bridge: MethodChannelBridge()).platformUuid(machineIdTimeout), macUuid);
      expect(calls.single.method, 'machineId');
    });

    test('is null with no plugin here, so ioreg is run', () async {
      expect(await SystemMachineIdSource(bridge: MethodChannelBridge()).platformUuid(machineIdTimeout), isNull);
    });

    test('is a read that did not finish when the plugin fails', () async {
      _native((_) => throw PlatformException(code: 'iokit'));
      await expectLater(SystemMachineIdSource(bridge: MethodChannelBridge()).platformUuid(machineIdTimeout),
          throwsA(isA<ReadFailure>().having((f) => f.unavailable, 'unavailable', isFalse)));
    });
  });

  group('the phone fingerprinter through the channel', () {
    test('asks machineId for the product, and hashes the answer', () async {
      final calls = _native((_) => 'ID-3');
      final fingerprinter = MobileFingerprinter(product: 'sluice', bridge: MethodChannelBridge(), system: 'ios');
      expect(await fingerprinter.get(), fp('machine-id|ios:ID-3'));
      expect(calls.single.arguments, {'product': 'sluice'});
    });

    test('gives no fingerprint for a native failure', () async {
      _native((_) => throw PlatformException(code: 'keychain'));
      final identity = await MobileFingerprinter(product: 'sluice', bridge: MethodChannelBridge(), system: 'ios')
          .identify(machineIdTimeout);
      expect(identity.fingerprint, isNull);
    });
  });

  group('the Keychain trial stash through the channel', () {
    test("reads a trial's start as the native side answers it", () async {
      final calls = _native((_) => 1757000000000);
      expect(await KeychainTrialStash('sluice', bridge: MethodChannelBridge()).readTrialStart(), 1757000000000);
      expect(calls.single.method, 'readTrialStart');
      expect(calls.single.arguments, {'product': 'sluice'});
    });

    test("writes a trial's start with the product", () async {
      final calls = _native((_) => null);
      await KeychainTrialStash('sluice', bridge: MethodChannelBridge()).writeTrialStart(1757000000000);
      expect(calls.single.method, 'writeTrialStart');
      expect(calls.single.arguments, {'product': 'sluice', 'start': 1757000000000});
    });

    test('throws a native failure for the SDK to swallow', () async {
      _native((_) => throw PlatformException(code: 'keychain'));
      await expectLater(KeychainTrialStash('sluice', bridge: MethodChannelBridge()).readTrialStart(), throwsA(isA<PlatformException>()));
    });
  });
}
