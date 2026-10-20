// The default storage's writes (the SDK contract, section 6; storage.test.ts
// `createFileStorage: writes`; FileStorageTests.swift): atomic, tried again
// when busy, and clearing what crashes left.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/storage.dart';
import 'package:keygrant/src/core/storage_fs.dart';

import '../support/storage_support.dart';

void main() {
  group('on this machine', () {
    test('writes by renaming a temp file over the state, and leaves no temp behind', () => inTemp((dir) async {
          final path = '$dir${sep}sluice.json';
          final storage = FileStorage.at(path);
          await storage.write(state({'key': 'K', 'lastSeen': 1}));
          await storage.write(state({'key': 'K', 'lastSeen': 2}));
          expect(jsonAt(path), {'key': 'K', 'lastSeen': 2});
          expect(namesIn(dir), ['sluice.json']);
        }));

    test('replaces the state rather than writing into it: a link to the old state keeps the old state', () => inTemp((dir) async {
          final path = '$dir${sep}sluice.json';
          final storage = FileStorage.at(path);
          await storage.write(state({'key': 'K', 'lastSeen': 1}));
          await _hardLink(path, '$dir${sep}old-state');
          await storage.write(state({'key': 'K', 'lastSeen': 2}));
          expect(jsonAt('$dir${sep}old-state'), {'key': 'K', 'lastSeen': 1});
          expect(jsonAt(path), {'key': 'K', 'lastSeen': 2});
        }));

    test('makes the folder it writes in', () => inTemp((dir) async {
          final path = '$dir${sep}a${sep}b${sep}sluice.json';
          await FileStorage.at(path).write(state({'key': 'K'}));
          expect(jsonAt(path), {'key': 'K'});
        }));

    test("clears the temps crashes left once a write lands, and not another instance's write in flight", () => inTemp((dir) async {
          String at(String name) => '$dir$sep$name';
          await writeAged(at('sluice.json.1.1.crashed.tmp'), '{"key":"CRASHED"}', 2 * staleTempMs);
          await writeAged(at('sluice.json.2.2.inflight.tmp'), '{"key":"IN');
          // Another product's temp in the same folder is not this file's to clear.
          await writeAged(at('maindeck.json.3.3.other.tmp'), '{}', 2 * staleTempMs);
          // Half the limit either side of it.
          await writeAged(at('sluice.json.4.4.younger.tmp'), '{}', staleTempMs ~/ 2);
          await writeAged(at('sluice.json.5.5.older.tmp'), '{}', staleTempMs * 3 ~/ 2);
          await FileStorage.at(at('sluice.json')).write(state({'key': 'K'}));
          expect(namesIn(dir), [
            'maindeck.json.3.3.other.tmp',
            'sluice.json',
            'sluice.json.2.2.inflight.tmp',
            'sluice.json.4.4.younger.tmp',
          ]);
          // The minute the integration guide promises.
          expect(staleTempMs, 60000);
        }));

    test('leaves the state as it was, and no temp, when a write fails', () => inTemp((dir) async {
          // The state path is a folder: the rename over it fails (EACCES on Windows, tried again).
          final path = '$dir${sep}sluice.json';
          await Directory(path).create();
          await expectLater(FileStorage.at(path, sleep: NoSleep().call).write(state({'key': 'K'})), throwsA(anything));
          expect(namesIn(dir), ['sluice.json']);
        }));
  });

  test('clears a temp aged exactly the cutoff, and keeps one a millisecond younger', () async {
    final edge = '$statePath.1.1.edge.tmp';
    final inside = '$statePath.2.2.inside.tmp';
    // The storage reads the system clock: tried until the write ran inside one millisecond.
    for (var attempt = 0; attempt < 50; attempt++) {
      final memory = MemoryFs({statePath: savedText, edge: '{}', inside: '{}'});
      final now = DateTime.now().millisecondsSinceEpoch;
      memory.mtimes[edge] = now - staleTempMs;
      memory.mtimes[inside] = now - staleTempMs + 1;
      await memoryStorage(memory).write(state({'key': 'K'}));
      if (DateTime.now().millisecondsSinceEpoch != now) continue;
      expect(memory.files.keys.toSet(), {statePath, inside});
      return;
    }
    fail('no write ran inside one millisecond');
  });

  for (final code in ['EPERM', 'EBUSY', 'EACCES']) {
    test('tries a rename Windows refuses as busy again: refused twice with $code, then made', () async {
      final memory = MemoryFs({statePath: savedText})..failNext(Op.rename, [code, code]);
      final sleep = NoSleep();
      await memoryStorage(memory, sleep).write(state({'key': 'K', 'lastSeen': 2}));
      expect(memory.json(), {'key': 'K', 'lastSeen': 2});
      expect(sleep.slept, hasLength(2));
      expect(memory.files.keys, [statePath]);
    });
  }

  test('gives up on a rename that stays busy after a second or two, keeping the state and removing its temp', () async {
    final memory = MemoryFs({statePath: savedText})..failAlways(Op.rename, 'EBUSY');
    final sleep = NoSleep();
    await expectLater(memoryStorage(memory, sleep).write(state({'key': 'K'})), throwsA(_code('EBUSY')));
    expect(sleep.total, inInclusiveRange(1000, 2000));
    expect(memory.files, {statePath: savedText});
  });

  test('does not try again a rename that failed other than for a busy file', () async {
    final memory = MemoryFs({statePath: savedText})..failNext(Op.rename, ['ENOSPC']);
    final sleep = NoSleep();
    await expectLater(memoryStorage(memory, sleep).write(state({'key': 'K'})), throwsA(_code('ENOSPC')));
    expect(sleep.slept, isEmpty);
    expect(memory.files, {statePath: savedText});
  });

  test('flushes the temp to the disk and closes it before the rename, and the folder after it', () async {
    final memory = MemoryFs({statePath: savedText});
    await memoryStorage(memory).write(state({'key': 'K'}));
    final steps = memory.steps.where((s) => !{'readdir', 'mtimeMs', 'mkdir'}.contains(s));
    expect(steps, ['create', 'write', 'sync', 'close', 'rename', 'syncDir']);
  });

  test('writes its temp beside the state, named for it, and unique to the write', () async {
    final memory = MemoryFs();
    await memoryStorage(memory).write(state({'key': 'K'}));
    await memoryStorage(memory).write(state({'key': 'K'}));
    final temps = [for (final op in memory.ops) if (op.startsWith('create ')) op.substring(7)];
    expect(temps, hasLength(2));
    expect(temps.toSet(), hasLength(2));
    for (final temp in temps) {
      expect(temp, startsWith('$statePath.$pid.'));
      expect(temp, endsWith('.tmp'));
    }
  });

  test('fails a write whose temp cannot be flushed, the state as it was and no temp', () async {
    final memory = MemoryFs({statePath: savedText})..failNext(Op.sync, ['EIO']);
    await expectLater(memoryStorage(memory).write(state({'key': 'K'})), throwsA(_code('EIO')));
    expect(memory.files, {statePath: savedText});
  });

  test('fails a write whose temp cannot be written, the state as it was and no temp', () async {
    final memory = MemoryFs({statePath: savedText})..failNext(Op.write, ['ENOSPC']);
    await expectLater(memoryStorage(memory).write(state({'key': 'K'})), throwsA(_code('ENOSPC')));
    expect(memory.files, {statePath: savedText});
  });

  test('fails nothing when the folder cannot be flushed: the rename has landed', () async {
    final memory = MemoryFs({statePath: savedText})..failNext(Op.syncDir, ['EINVAL']);
    await memoryStorage(memory).write(state({'key': 'K'}));
    expect(memory.files, {statePath: '{"key":"K"}'});
  });

  test('fails nothing when the stale temps cannot be listed or removed', () async {
    final old = '$statePath.1.1.crashed.tmp';
    final memory = MemoryFs({statePath: savedText, old: '{}'})..failAlways(Op.rm, 'EBUSY');
    memory.mtimes[old] = 0;
    await memoryStorage(memory).write(state({'key': 'K'}));
    expect(memory.files[statePath], '{"key":"K"}');
    final listless = MemoryFs({statePath: savedText})..failAlways(Op.readdir, 'EIO');
    await memoryStorage(listless).write(state({'key': 'L'}));
    expect(listless.files[statePath], '{"key":"L"}');
  });
}

Matcher _code(String code) => isA<StorageFsException>().having((e) => e.code, 'code', code);

/// A second name for the file at `target`.
Future<void> _hardLink(String target, String link) async {
  final result = Platform.isWindows
      ? await Process.run('cmd', ['/c', 'mklink', '/H', link, target])
      : await Process.run('ln', [target, link]);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}
