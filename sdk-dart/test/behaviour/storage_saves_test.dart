// Saves from more than one process, and a state that cannot be read (the SDK
// contract, section 6; storage.test.ts `saves from more than one process`
// and `on a read that stays busy`).

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/storage.dart';
import 'package:keygrant/src/core/storage_fs.dart';

import '../support/harness.dart';
import '../support/storage_support.dart';

void main() {
  test('stamps every save with the next revision', () async {
    final memory = MemoryFs();
    final storage = memoryStorage(memory);
    await storage.update(setting({'key': 'K'}));
    expect(memory.json(), {'key': 'K', 'rev': 1});
    await storage.update(setting({'checkedMajor': 2}));
    expect(memory.json(), {'key': 'K', 'checkedMajor': 2, 'rev': 2});
  });

  test('a plain write stamps nothing', () async {
    final memory = MemoryFs();
    await memoryStorage(memory).write(state({'key': 'K'}));
    expect(memory.json(), {'key': 'K'});
  });

  final onto = {
    'a stamped state': {statePath: '{"key":"K","rev":4}'},
    "an older SDK's state, never stamped": {statePath: '{"key":"K"}'},
    'no state yet': <String, String>{},
  };
  for (final MapEntry(key: name, value: files) in onto.entries) {
    test('loses neither of two saves that interleave, onto $name', () async {
      final memory = MemoryFs(files);
      final a = memoryStorage(memory);
      final b = memoryStorage(memory);
      // A has read the state and is about to write it; B saves in between.
      final held = memory.holdNext(Op.create);
      final first = a.update(setting({'keptMajor': 2}));
      await untilReached(held, 'the first save', first);
      await b.update(setting({'checkedMajor': 3}));
      held.release();
      await first;
      expect(memory.json(), allOf(containsPair('keptMajor', 2), containsPair('checkedMajor', 3)));
      expect(memory.files.keys, [statePath]);
    });
  }

  test('merges again onto the state another process saved, so a field it removed stays removed', () async {
    final memory = MemoryFs({statePath: '{"key":"K","activationId":"act_1","refused":"revoked","rev":4}'});
    final a = memoryStorage(memory);
    final b = memoryStorage(memory);
    final held = memory.holdNext(Op.create);
    final first = a.update(setting({'keptMajor': 2}));
    await untilReached(held, 'the first save', first);
    await b.update((latest) => state({...latest.toJson()}..remove('refused')));
    held.release();
    await first;
    expect(memory.json(), {'key': 'K', 'activationId': 'act_1', 'keptMajor': 2, 'rev': 6});
  });

  test("fails with a conflict after a few tries when the state keeps changing under it, keeping the other's", () async {
    final memory = MemoryFs({statePath: '{"key":"K","rev":1}'});
    var other = 1;
    // Another process saves every time this one has read and is about to write.
    memory.before[Op.create] = () => memory.files[statePath] = '{"key":"OTHER","rev":${++other}}';
    await expectLater(
      memoryStorage(memory).update(setting({'keptMajor': 2})),
      throwsA(isA<StorageFsException>().having((e) => e.code, 'code', 'ECONFLICT')),
    );
    expect(memory.steps.where((s) => s == 'create'), hasLength(updateAttempts));
    expect(updateAttempts, 5);
    expect(memory.json(), {'key': 'OTHER', 'rev': other});
    expect(memory.files.keys, [statePath]);
  });

  test('takes a state that came back after a conflict on the next try', () async {
    final memory = MemoryFs({statePath: '{"key":"K","rev":1}'});
    var saves = 0;
    memory.before[Op.create] = () {
      if (++saves == 1) memory.files[statePath] = '{"key":"K","checkedMajor":3,"rev":2}';
    };
    await memoryStorage(memory).update(setting({'keptMajor': 2}));
    expect(memory.json(), {'key': 'K', 'checkedMajor': 3, 'keptMajor': 2, 'rev': 3});
  });

  test('fails with a sentence, not a hang, when the held operation is never reached', () async {
    final held = MemoryFs().holdNext(Op.create);
    await expectLater(
      untilReached(held, 'nothing', Future<void>.delayed(const Duration(days: 1)), within: const Duration(milliseconds: 50)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'nothing never reached its held operation')),
    );
  });

  test('fails at once, saying so, when the call finishes or fails without reaching its hold', () async {
    final held = MemoryFs().holdNext(Op.create);
    final message = isA<StateError>().having((e) => e.message, 'message', 'a read finished without reaching its held operation');
    await expectLater(untilReached(held, 'a read', Future.value('done')), throwsA(message));
    await expectLater(
      untilReached(held, 'a save', Future<void>.error('EACCES')),
      throwsA(isA<StateError>().having((e) => e.message, 'message', endsWith(': EACCES'))),
    );
  });

  test('on a read that stays busy: status() is unknown, activate() throws, nothing asked or written', () async {
    // Every save is read, patch, write: a read taken as "no state" would be
    // written back over the licence.
    final memory = MemoryFs({statePath: savedText})..failAlways(Op.readFile, 'EBUSY');
    final http = FakeHttp();
    final license = await _licenseOver(memory, http);
    const unknown = (LicenseState.unknown, LicenseReason.storage);
    for (final status in [await license.status(), await license.refresh(), await license.startTrial()]) {
      expect((status.state, status.reason), unknown);
    }
    final busy = throwsA(isA<StorageFsException>().having((e) => e.code, 'code', 'EBUSY'));
    await expectLater(license.activate('SLUICE-EEEE-FFFF-GGGG-HHHH'), busy);
    await expectLater(license.deactivate(), busy);
    expect(http.calls, isEmpty);
    expect(memory.files, {statePath: savedText});
    expect(memory.changes, isEmpty);
  });

  test('a licence over the default storage on a disk activates and reads its state back', () => inTemp((dir) async {
        final signer = await Signer.create();
        final http = FakeHttp()..on('activate', (_) async => HttpResponse(200, {'lease': await signer.lease(key1), 'activationId': 'act_1'}));
        final path = '$dir${sep}sluice.json';
        KeyGrantLicense over() => KeyGrantLicense(LicenseConfig(
              product: product,
              apiBaseUrl: 'https://api.test',
              publicJwk: signer.publicJwk,
              adapters: LicenseAdapters(storage: FileStorage.at(path), http: http, clock: FakeClock(), fingerprinter: const PlainFingerprinter(), registry: FakeStash()),
            ));
        expect((await over().activate(key1)).ok, isTrue);
        final status = await over().status();
        expect((status.state, status.key), (LicenseState.licensed, key1));
        expect(namesIn(dir), ['sluice.json']);
      }));
}

Future<KeyGrantLicense> _licenseOver(MemoryFs memory, FakeHttp http) async {
  final signer = await Signer.create();
  return KeyGrantLicense(LicenseConfig(
    product: product,
    apiBaseUrl: 'https://api.test',
    publicJwk: signer.publicJwk,
    adapters: LicenseAdapters(
      storage: memoryStorage(memory),
      http: http,
      clock: FakeClock(),
      fingerprinter: const PlainFingerprinter(),
      registry: FakeStash(),
    ),
  ));
}
