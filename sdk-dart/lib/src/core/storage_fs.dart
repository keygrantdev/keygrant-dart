/// The file operations under the default storage (storage-fs.ts), and what it
/// does around them: tries again on a busy file, a temp file synced to the
/// disk, and the clearing of what crashes and corrupt files leave behind.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'posix_sync.dart';
import 'stored_state.dart';

/// A failed file operation, by what it means: `ENOENT` (missing), `EBUSY`,
/// `EPERM`, `EACCES` (busy or not ours just now), or another code.
final class StorageFsException implements Exception {
  const StorageFsException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'StorageFsException($code) $message';
}

/// A new file being written: what is written is flushed to the disk by [sync].
abstract interface class StorageFile {
  Future<void> write(String data);
  Future<void> sync();
  Future<void> close();
}

/// The file operations the storage uses: the real ones, or stand-ins in tests.
/// Each throws a [StorageFsException] when it fails.
abstract interface class StorageFs {
  Future<String> readFile(String path);

  /// A new file to write, failing when there is one by that name.
  Future<StorageFile> create(String path);
  Future<void> rename(String from, String to);
  Future<void> rm(String path);
  Future<List<String>> readdir(String dir);
  Future<int> mtimeMs(String path);
  Future<void> mkdir(String dir);

  /// Flush a folder's entries (a rename in it) to the disk.
  Future<void> syncDir(String dir);
}

/// What an OS error code means, on POSIX and on Windows.
String codeOfOs(OSError? error) {
  final code = error?.errorCode;
  if (Platform.isWindows) {
    return switch (code) {
      2 || 3 => 'ENOENT',
      5 => 'EACCES',
      32 || 33 => 'EBUSY',
      _ => 'E$code',
    };
  }
  return switch (code) {
    2 => 'ENOENT',
    1 => 'EPERM',
    13 => 'EACCES',
    16 => 'EBUSY',
    _ => 'E$code',
  };
}

Future<T> _io<T>(Future<T> Function() work) async {
  try {
    return await work();
  } on FileSystemException catch (e) {
    throw StorageFsException(codeOfOs(e.osError), e.message);
  }
}

/// The real file system, through dart:io.
final class IoStorageFs implements StorageFs {
  const IoStorageFs();

  /// Bytes that are not UTF-8 read as U+FFFD, as Node's `readFile(path,
  /// 'utf8')` reads them: such a file does not parse and is set aside, where a
  /// decoding error would fail every read of it.
  @override
  Future<String> readFile(String path) =>
      _io(() async => utf8.decode(await File(path).readAsBytes(), allowMalformed: true));

  @override
  Future<StorageFile> create(String path) => _io(() async {
        try {
          await File(path).create(exclusive: true);
        } on FileSystemException {
          if (await File(path).exists()) throw const StorageFsException('EEXIST');
          rethrow;
        }
        return _IoFile(await File(path).open(mode: FileMode.writeOnly));
      });

  @override
  Future<void> rename(String from, String to) => _io(() => File(from).rename(to));

  @override
  Future<void> rm(String path) => _io(() async {
        final file = File(path);
        if (await file.exists()) await file.delete();
      });

  @override
  Future<List<String>> readdir(String dir) => _io(() async => [
        await for (final entry in Directory(dir).list()) entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
      ]);

  @override
  Future<int> mtimeMs(String path) => _io(() async {
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.notFound) throw const StorageFsException('ENOENT');
        return stat.modified.millisecondsSinceEpoch;
      });

  @override
  Future<void> mkdir(String dir) => _io(() => Directory(dir).create(recursive: true));

  @override
  Future<void> syncDir(String dir) async => syncDirectory(dir);
}

final class _IoFile implements StorageFile {
  _IoFile(this._file);
  final RandomAccessFile _file;
  @override
  Future<void> write(String data) => _io(() => _file.writeString(data, encoding: utf8));
  @override
  Future<void> sync() => _io(() => _file.flush());
  @override
  Future<void> close() => _io(() => _file.close());
}

/// Waits between tries of a read that failed other than for a missing file: about a second in all.
const List<int> readBackoffMs = [50, 100, 200, 300, 350];

/// Waits between tries of a rename a busy file refused: about a second and a half in all.
const List<int> renameBackoffMs = [50, 100, 200, 400, 800];

String? codeOf(Object error) => error is StorageFsException ? error.code : null;
bool busy(String? code) => code == 'EBUSY' || code == 'EPERM' || code == 'EACCES';
bool missing(String? code) => code == 'ENOENT';

/// How many set-aside `.corrupt` files of a state file are kept: the newest.
const int keepCorrupt = 3;

/// How old a temp file must be to be a crash's leftover (ms).
const int staleTempMs = 60000;

/// `work`, tried again after each wait in `backoff` while its error is worth another try.
Future<T> retrying<T>(Future<T> Function() work, List<int> backoff, bool Function(String? code) worthAgain,
    Future<void> Function(int ms) sleep) async {
  for (final wait in backoff) {
    try {
      return await work();
    } catch (error) {
      if (!worthAgain(codeOf(error))) rethrow;
      await sleep(wait);
    }
  }
  return work();
}

/// A file's text, tried again for about a second on any failure but a missing
/// file; null when it is missing.
Future<String?> readText(StorageFs fs, String path, Future<void> Function(int ms) sleep) async {
  try {
    return await retrying(() => fs.readFile(path), readBackoffMs, (code) => !missing(code), sleep);
  } catch (error) {
    if (missing(codeOf(error))) return null;
    rethrow;
  }
}

final Random _random = Random();

/// A state written whole to a new temp file in `dir` and flushed to the disk
/// before it is closed. Removed when it fails.
Future<String> writeTemp(StorageFs fs, String dir, String prefix, StoredState state) async {
  await fs.mkdir(dir);
  final unique = '$pid.${DateTime.now().millisecondsSinceEpoch}.${_random.nextInt(1 << 32).toRadixString(36)}';
  final temp = '$dir${Platform.pathSeparator}$prefix$unique.tmp';
  try {
    final file = await fs.create(temp);
    try {
      await file.write(jsonEncode(state.toJson()));
      await file.sync();
    } finally {
      await file.close();
    }
    return temp;
  } catch (_) {
    await _quietly(() => fs.rm(temp));
    rethrow;
  }
}

Future<void> _quietly(Future<void> Function() work) async {
  try {
    await work();
  } catch (_) {}
}

Future<List<String>> _temps(StorageFs fs, String dir, String prefix) async =>
    [for (final name in await fs.readdir(dir)) if (name.startsWith(prefix) && name.endsWith('.tmp')) name];

/// The newest temp file of a storage file that parses, when the file itself is missing. Never throws.
Future<StoredState?> leftover(StorageFs fs, String dir, String prefix) async {
  try {
    final dated = [
      for (final name in await _temps(fs, dir, prefix)) (name: name, at: await fs.mtimeMs('$dir${Platform.pathSeparator}$name')),
    ]..sort((a, b) => b.at.compareTo(a.at));
    for (final (:name, at: _) in dated) {
      try {
        return StoredState.fromJson(jsonDecode(await fs.readFile('$dir${Platform.pathSeparator}$name')));
      } catch (_) {
        // Torn: the next older one.
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Remove a storage file's temp files older than [staleTempMs]. Best-effort.
Future<void> clearStale(StorageFs fs, String dir, String prefix) async {
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final name in await _temps(fs, dir, prefix)) {
      final path = '$dir${Platform.pathSeparator}$name';
      int at;
      try {
        at = await fs.mtimeMs(path);
      } catch (_) {
        at = now;
      }
      if (now - at >= staleTempMs) await _quietly(() => fs.rm(path));
    }
  } catch (_) {
    // Left for the next write.
  }
}

/// Remove all but the newest [keepCorrupt] set-aside files of a state file,
/// newest by the time in their name. Best-effort.
Future<void> pruneCorrupt(StorageFs fs, String dir, String prefix) async {
  try {
    final pattern = RegExp(r'^(\d+)\.corrupt$');
    final aside = <({String name, int at})>[];
    for (final name in await fs.readdir(dir)) {
      final match = name.startsWith(prefix) ? pattern.firstMatch(name.substring(prefix.length)) : null;
      if (match != null) aside.add((name: name, at: int.parse(match[1]!)));
    }
    aside.sort((a, b) => b.at.compareTo(a.at));
    for (final (:name, at: _) in aside.skip(keepCorrupt)) {
      await _quietly(() => fs.rm('$dir${Platform.pathSeparator}$name'));
    }
  } catch (_) {
    // Kept until the next one is set aside.
  }
}
