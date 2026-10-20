// The phone and tablet fingerprinter (the SDK contract, section 4.1) over a
// fake platform bridge: iOS's Keychain install id, Android's ANDROID_ID or the
// SDK's own install id, never a host name; and the iOS Keychain trial stash.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/defaults.dart';
import 'package:keygrant/src/core/fingerprinters.dart';
import 'package:keygrant/src/core/platform_bridge.dart';

import '../support/adapters_support.dart';
import '../support/storage_support.dart' show inTemp, sep;

const _bound = Duration(seconds: 1);
final _uuidV4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

MobileFingerprinter _on(String system, PlatformBridge bridge) =>
    MobileFingerprinter(product: 'sluice', bridge: bridge, system: system);

Future<Map<String, Object?>> _identify(MobileFingerprinter f) async => (await f.identify(_bound)).toJson();

const _none = {'fingerprint': null, 'alternates': <String>[]};

void main() {
  group('iOS', () {
    test('hashes the Keychain install id as machine-id|ios:<id>, kind machine, no alternate', () async {
      final bridge = answering('5D3F1B0E-1111-4222-8333-944455556666');
      expect(await _identify(_on('ios', bridge)), {
        'fingerprint': fp('machine-id|ios:5D3F1B0E-1111-4222-8333-944455556666'),
        'kind': 'machine',
        'alternates': <String>[],
      });
      expect(bridge.called, [[NativeMethod.machineId, {'product': 'sluice'}]]);
    });

    test('gives no fingerprint for an empty answer, or none, and reads again next call', () async {
      for (final answer in ['', null, 42]) {
        final bridge = answering(answer);
        final fingerprinter = _on('ios', bridge);
        expect(await _identify(fingerprinter), _none);
        await fingerprinter.identify(_bound);
        expect(bridge.calls, hasLength(2));
      }
    });

    test('gives no fingerprint when the Keychain read throws, never a stand-in', () async {
      final fingerprinter = _on('ios', FakeBridge(answer: (_, __) => throw Exception('locked since boot')));
      expect(await _identify(fingerprinter), _none);
      await expectLater(fingerprinter.get(), throwsStateError);
      expect(await _identify(_on('ios', const NoPlatformBridge())), _none);
    });

    test('keeps the id once settled: read once for every call after', () async {
      var reads = 0;
      final bridge = FakeBridge(answer: (_, __) => ++reads == 1 ? throw Exception('locked') : 'ID-1');
      final fingerprinter = _on('ios', bridge);
      expect((await fingerprinter.identify(_bound)).fingerprint, isNull);
      expect((await fingerprinter.identify(_bound)).fingerprint, fp('machine-id|ios:ID-1'));
      expect(await fingerprinter.get(), fp('machine-id|ios:ID-1'));
      expect(bridge.calls, hasLength(2));
    });

    test('gives no fingerprint once its time box is out when the channel never answers', () async {
      final fingerprinter = _on('ios', FakeBridge(answer: (_, __) => Completer<Object?>().future));
      final started = DateTime.now();
      expect((await fingerprinter.identify(const Duration(milliseconds: 50))).fingerprint, isNull);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 3)));
    });
  });

  group('Android', () {
    test('hashes ANDROID_ID lower-cased as machine-id|android:<id>, kind machine, no alternate', () async {
      expect(await _identify(_on('android', answering('9A1B2C3D4E5F6071'))), {
        'fingerprint': fp('machine-id|android:9a1b2c3d4e5f6071'),
        'kind': 'machine',
        'alternates': <String>[],
      });
    });

    test('reads no answer at all as cannot tell this time: no fingerprint, and no install id made', () => inTemp((dir) async {
          expect(await _identify(_on('android', answering(null, support: dir))), _none);
          expect(File('$dir${sep}KeyGrant${sep}install-id').existsSync(), isFalse);
        }));

    for (final (name, answer) in [('an empty ANDROID_ID', ''), ('the value old builds share', sharedAndroidId)]) {
      test('keeps an install id of its own for $name: install-id|android:<uuid>, of no kind', () => inTemp((dir) async {
            final fingerprinter = _on('android', answering(answer, support: dir));
            final identity = await fingerprinter.identify(_bound);
            final kept = File('$dir${sep}KeyGrant${sep}install-id').readAsStringSync();
            expect(kept, matches(_uuidV4));
            expect(identity.toJson(), {'fingerprint': fp('install-id|android:$kept'), 'alternates': <String>[]});
          }));
    }

    test('reads the shared value in upper case as the shared value', () => inTemp((dir) async {
          final identity = await _on('android', answering(sharedAndroidId.toUpperCase(), support: dir)).identify(_bound);
          expect(identity.kind, isNull);
          expect(File('$dir${sep}KeyGrant${sep}install-id').existsSync(), isTrue);
        }));

    test('reuses the install id it kept, from one run to the next', () => inTemp((dir) async {
          final first = await _on('android', answering('', support: dir)).get();
          final second = await _on('android', answering('', support: dir)).get();
          expect(second, first);
          final kept = File('$dir${sep}KeyGrant${sep}install-id').readAsStringSync();
          expect(first, fp('install-id|android:$kept'));
        }));

    test('reads an install id kept with a line end as the id, and makes a new one for an empty file', () => inTemp((dir) async {
          final file = File('$dir${sep}KeyGrant${sep}install-id')..createSync(recursive: true);
          file.writeAsStringSync('0f0e0d0c-0b0a-4908-8706-050403020100\n');
          expect(await _on('android', answering('', support: dir)).get(), fp('install-id|android:0f0e0d0c-0b0a-4908-8706-050403020100'));
          file.writeAsStringSync('');
          await _on('android', answering('', support: dir)).get();
          expect(file.readAsStringSync(), matches(_uuidV4));
        }));

    test('gives no fingerprint when ANDROID_ID cannot be read, or the support folder cannot be asked', () async {
      expect(await _identify(_on('android', FakeBridge(answer: (_, __) => throw Exception('no')))), _none);
      expect(await _identify(_on('android', answering(''))), _none);
    });

    test('keeps the id once settled', () async {
      final bridge = answering('abc123');
      final fingerprinter = _on('android', bridge);
      await fingerprinter.identify(_bound);
      await fingerprinter.identify(_bound);
      expect(bridge.calls, hasLength(1));
    });
  });

  test('makes version 4 UUIDs, lower case, each new', () {
    final made = {for (var i = 0; i < 50; i++) uuidV4()};
    expect(made, hasLength(50));
    for (final uuid in made) {
      expect(uuid, matches(_uuidV4));
    }
  });

  test('uses the bridge the plugin set when given none', () async {
    final before = PlatformBridge.instance;
    addTearDown(() => PlatformBridge.instance = before);
    PlatformBridge.instance = answering('ID-2');
    expect(await MobileFingerprinter(product: 'sluice', system: 'ios').get(), fp('machine-id|ios:ID-2'));
  });

  group('the Keychain trial stash', () {
    test("reads a trial's start for the product", () async {
      final bridge = answering(1757000000000);
      expect(await KeychainTrialStash('sluice', bridge: bridge).readTrialStart(), 1757000000000);
      expect(bridge.called, [[NativeMethod.readTrialStart, {'product': 'sluice'}]]);
    });

    test('reads none, a zero, a negative or a non-number as no start', () async {
      for (final answer in [null, 0, -5, '1757000000000', 1.5]) {
        expect(await KeychainTrialStash('sluice', bridge: answering(answer)).readTrialStart(), isNull, reason: '$answer');
      }
    });

    test("writes a trial's start for the product", () async {
      final bridge = answering(null);
      await KeychainTrialStash('sluice', bridge: bridge).writeTrialStart(1757000000000);
      expect(bridge.called, [[NativeMethod.writeTrialStart, {'product': 'sluice', 'start': 1757000000000}]]);
    });

    test('throws what the channel throws, which the SDK never lets cost the customer anything', () async {
      final stash = KeychainTrialStash('sluice', bridge: const NoPlatformBridge());
      await expectLater(stash.readTrialStart(), throwsA(isA<NoPlatformChannel>()));
      await expectLater(stash.writeTrialStart(1), throwsA(isA<NoPlatformChannel>()));
    });

    test('uses the bridge the plugin set when given none, and is no default off iOS', () async {
      final before = PlatformBridge.instance;
      addTearDown(() => PlatformBridge.instance = before);
      PlatformBridge.instance = answering(7);
      expect(await KeychainTrialStash('sluice').readTrialStart(), 7);
      expect(defaultRegistry('sluice'), isA<NoRegistryStash>());
      expect(defaultFingerprinter('sluice'), isA<DesktopFingerprinter>());
    });
  });
}
