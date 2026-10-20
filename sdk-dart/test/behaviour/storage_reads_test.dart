// The default storage's reads (the SDK contract, section 6; storage.test.ts
// `createFileStorage: reads`; FileStorageTests.swift): only a missing file is
// no state, a leftover temp read first, a corrupt file set aside, and a
// read-only read writing nothing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/storage.dart';
import 'package:keygrant/src/core/storage_fs.dart';

import '../support/storage_support.dart';

void main() {
  group('on this machine', () {
    test('returns null when the file does not exist, then round-trips state', () => inTemp((dir) async {
          final storage = FileStorage.at('$dir${sep}nested${sep}license.json');
          expect(await storage.read(), isNull);
          final kept = state({'key': 'K', 'activationId': 'a', 'lastSeen': 42, 'future': {'x': 1}});
          await storage.write(kept);
          expect(await storage.read(), kept);
        }));

    test('reads the state it had when a write crashed before its rename: the temp is there, the state whole', () => inTemp((dir) async {
          final path = '$dir${sep}sluice.json';
          await FileStorage.at(path).write(state({'key': 'OLD', 'lastSeen': 1}));
          await writeAged('$dir${sep}sluice.json.123.456.abc.tmp', '{"key":"NE');
          expect(await FileStorage.at(path).read(), state({'key': 'OLD', 'lastSeen': 1}));
        }));

    test('reads the newest temp that parses when the state itself is missing, by its time, not its name', () => inTemp((dir) async {
          final path = '$dir${sep}sluice.json';
          // Named so that their names sort the opposite way to their times.
          final newer = '$dir${sep}sluice.json.1.1.a.tmp';
          final older = '$dir${sep}sluice.json.9.9.z.tmp';
          final torn = '$dir${sep}sluice.json.5.5.m.tmp';
          await writeAged(newer, '{"key":"NEW"}', 20000);
          await writeAged(older, '{"key":"OLD"}', 30000);
          await writeAged(torn, '{"key":"TOR', 10000);
          expect(await FileStorage.at(path).read(), state({'key': 'NEW'}));
          // A read-only read reads it too, and writes nothing.
          expect(await FileStorage.at(path).read(readOnly: true), state({'key': 'NEW'}));
          expect(namesIn(dir), hasLength(3));
          await File(newer).delete();
          expect(await FileStorage.at(path).read(), state({'key': 'OLD'}));
          await File(older).delete();
          expect(await FileStorage.at(path).read(), isNull);
        }));

    test('sets a file that does not parse aside and starts afresh, never from a temp', () => inTemp((dir) async {
          final path = '$dir${sep}sluice.json';
          await writeAged(path, '{"key":"SLUICE-AA');
          await writeAged('$dir${sep}sluice.json.1.1.a.tmp', '{"key":"FROM-A-TEMP"}');
          final storage = FileStorage.at(path);
          expect(await storage.read(), isNull);
          final aside = namesIn(dir).where((n) => RegExp(r'^sluice\.json\.\d+\.corrupt$').hasMatch(n)).single;
          expect(File('$dir$sep$aside').readAsStringSync(), '{"key":"SLUICE-AA');
          // An empty state in its place, so no later read takes the temp instead.
          expect(await storage.read(), state({}));
        }));

    test('sets a file whose bytes are not UTF-8 aside as one that does not parse', () => inTemp((dir) async {
          final path = '$dir${sep}sluice.json';
          await File(path).writeAsBytes([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d]);
          final storage = FileStorage.at(path, sleep: NoSleep().call);
          expect(await storage.read(), isNull);
          expect(namesIn(dir).where((n) => n.endsWith('.corrupt')), hasLength(1));
          expect(await storage.read(), state({}));
        }));
  });

  test('reads a file holding null as no state, setting nothing aside and writing nothing', () async {
    final memory = MemoryFs({statePath: 'null'});
    expect(await memoryStorage(memory).read(), isNull);
    expect(await memoryStorage(memory).read(readOnly: true), isNull);
    expect(memory.changes, isEmpty);
    expect(memory.files, {statePath: 'null'});
  });

  test('keeps only the newest set-aside files of a state file, by the time in their names', () async {
    String aside(int at) => '$statePath.$at.corrupt';
    // 900 sorts after 3000 as text: only the numbers tell which is newest.
    // `tunnel.json.` is as long as `sluice.json.`: what follows it would read as a time.
    final others = {'$stateDir${sep}tunnel.json.100.corrupt': 'x', '$statePath.notes.corrupt': 'x'};
    final memory = MemoryFs({
      statePath: '{"bad',
      for (final at in [900, 1000, 2000, 3000]) aside(at): 'x',
      ...others,
    });
    expect(await memoryStorage(memory).read(), isNull);
    final kept = memory.files.keys.where((n) => RegExp(r'sluice\.json\.\d+\.corrupt$').hasMatch(n)).toList();
    expect(kept, hasLength(keepCorrupt));
    expect(kept, containsAll([aside(3000), aside(2000)]));
    expect(memory.files.containsKey(aside(1000)), isFalse);
    expect(memory.files.containsKey(aside(900)), isFalse);
    for (final MapEntry(:key, :value) in others.entries) {
      expect(memory.files[key], value);
    }
    expect(memory.files[statePath], '{}');
  });

  test('reads read-only without repairing: a file that does not parse is no state, and stays as it is', () async {
    final memory = MemoryFs({statePath: '{"bad'});
    expect(await memoryStorage(memory).read(readOnly: true), isNull);
    expect(memory.files, {statePath: '{"bad'});
    expect(memory.changes, isEmpty);
  });

  test('tries a read that failed again: busy once, then the state', () async {
    final memory = MemoryFs({statePath: savedText})..failNext(Op.readFile, ['EBUSY']);
    final sleep = NoSleep();
    expect(await memoryStorage(memory, sleep).read(), state(jsonDecode(savedText) as Map<String, Object?>));
    expect(sleep.slept, hasLength(1));
  });

  for (final code in ['EBUSY', 'EACCES', 'EIO']) {
    test('throws on a read that still fails ($code) after about a second, rather than reading no state or a temp', () async {
      final memory = MemoryFs({statePath: savedText, '$statePath.1.1.a.tmp': '{"key":"FROM-A-TEMP"}'})
        ..failAlways(Op.readFile, code);
      final sleep = NoSleep();
      await expectLater(memoryStorage(memory, sleep).read(), throwsA(_code(code)));
      expect(sleep.total, inInclusiveRange(500, 1500));
      expect(memory.changes, isEmpty);
    });
  }

  test('does not wait on a missing file', () async {
    final sleep = NoSleep();
    expect(await memoryStorage(MemoryFs(), sleep).read(), isNull);
    expect(sleep.slept, isEmpty);
  });

  test('reads no state, and throws nothing, when the leftover temps cannot be listed', () async {
    final memory = MemoryFs()..failAlways(Op.readdir, 'EIO');
    expect(await memoryStorage(memory).read(), isNull);
    expect(memory.changes, isEmpty);
  });

  test('throws, writing nothing, when a file that does not parse cannot be set aside', () async {
    final memory = MemoryFs({statePath: '{"key":"SLUICE-AA'})..failAlways(Op.rename, 'EBUSY');
    await expectLater(memoryStorage(memory).read(), throwsA(_code('EBUSY')));
    expect(memory.files, {statePath: '{"key":"SLUICE-AA'});
  });

  test('still reads no state when the empty state cannot be written after the set-aside', () async {
    final memory = MemoryFs({statePath: '{"bad'})..failNext(Op.create, ['ENOSPC']);
    expect(await memoryStorage(memory).read(), isNull);
    expect(memory.files.keys.single, matches(RegExp(r'sluice\.json\.\d+\.corrupt$')));
  });

  test('names a file it sets aside by the time it was set aside', () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final memory = MemoryFs({statePath: '{"bad'});
    await memoryStorage(memory).read();
    final after = DateTime.now().millisecondsSinceEpoch;
    final aside = memory.files.keys.firstWhere((n) => n.endsWith('.corrupt'));
    final at = int.parse(RegExp(r'\.(\d+)\.corrupt$').firstMatch(aside)![1]!);
    expect(at, inInclusiveRange(before, after));
    expect(memory.files[aside], '{"bad');
  });
}

Matcher _code(String code) => isA<StorageFsException>().having((e) => e.code, 'code', code);
