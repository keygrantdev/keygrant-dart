// What the storage tests share (the reference's storage.test.ts): files in memory as
// one or more processes see them, with failures, holds and hooks per
// operation; waits that take no time; and a temp folder on this machine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keygrant/src/core/storage.dart';
import 'package:keygrant/src/core/storage_fs.dart';
import 'package:keygrant/src/core/stored_state.dart';

final String sep = Platform.pathSeparator;
final String stateDir = '${sep}memory${sep}keygrant';
final String statePath = '$stateDir${sep}sluice.json';
const String savedText = '{"key":"SLUICE-AAAA-BBBB-CCCC-DDDD","activationId":"act_1","lastSeen":1}';

/// The file operations a [MemoryFs] can fail, hold or hook.
enum Op { readFile, create, write, sync, close, rename, rm, readdir, mtimeMs, mkdir, syncDir }

/// An operation held until [release]; [reached] once something waits on it.
final class Hold {
  final Completer<void> _held = Completer<void>();
  bool reached = false;
  void release() => _held.complete();
}

/// Files in memory: failures queued per operation ([failNext]) or given every
/// time ([failAlways]), an operation held until released ([holdNext]),
/// something another process does just before an operation ([before]), each
/// file's mtime ([mtimes], else now), every operation in order ([ops]) and
/// every one that changes a file ([changes]).
final class MemoryFs implements StorageFs {
  MemoryFs([Map<String, String> files = const {}]) : files = {...files};

  final Map<String, String> files;
  final Map<String, int> mtimes = {};
  final List<String> ops = [];
  final List<String> changes = [];
  final Map<Op, void Function()> before = {};
  final Map<Op, List<String>> _queued = {};
  final Map<Op, String> _always = {};
  final Map<Op, List<Hold>> _holds = {};

  void failNext(Op op, List<String> codes) => (_queued[op] ??= []).addAll(codes);
  void failAlways(Op op, String code) => _always[op] = code;

  Hold holdNext(Op op) {
    final hold = Hold();
    (_holds[op] ??= []).add(hold);
    return hold;
  }

  /// The operations by name alone, in order.
  List<String> get steps => [for (final op in ops) op.split(' ').first];

  Future<void> _enter(Op op, String path, {bool changing = false}) async {
    before[op]?.call();
    final holds = _holds[op];
    if (holds != null && holds.isNotEmpty) {
      final hold = holds.removeAt(0);
      hold.reached = true;
      await hold._held.future;
    }
    final queued = _queued[op];
    final code = queued != null && queued.isNotEmpty ? queued.removeAt(0) : _always[op];
    if (code != null) throw StorageFsException(code, 'the file system said no');
    ops.add('${op.name} $path');
    if (changing) changes.add('${op.name} $path');
  }

  @override
  Future<String> readFile(String path) async {
    await _enter(Op.readFile, path);
    return files[path] ?? (throw const StorageFsException('ENOENT'));
  }

  @override
  Future<StorageFile> create(String path) async {
    await _enter(Op.create, path, changing: true);
    if (files.containsKey(path)) throw const StorageFsException('EEXIST');
    files[path] = '';
    return _MemoryFile(this, path);
  }

  @override
  Future<void> rename(String from, String to) async {
    await _enter(Op.rename, '$from $to', changing: true);
    final text = files.remove(from) ?? (throw const StorageFsException('ENOENT'));
    files[to] = text;
  }

  @override
  Future<void> rm(String path) async {
    await _enter(Op.rm, path, changing: true);
    files.remove(path);
  }

  @override
  Future<List<String>> readdir(String dir) async {
    await _enter(Op.readdir, dir);
    return [for (final path in files.keys) if (splitPath(path).dir == dir) splitPath(path).name];
  }

  @override
  Future<int> mtimeMs(String path) async {
    await _enter(Op.mtimeMs, path);
    return mtimes[path] ?? DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<void> mkdir(String dir) => _enter(Op.mkdir, dir);

  @override
  Future<void> syncDir(String dir) => _enter(Op.syncDir, dir);

  /// The state file's JSON.
  Map<String, Object?> json([String? path]) => jsonDecode(files[path ?? statePath]!) as Map<String, Object?>;
}

final class _MemoryFile implements StorageFile {
  _MemoryFile(this._fs, this._path);
  final MemoryFs _fs;
  final String _path;

  @override
  Future<void> write(String data) async {
    await _fs._enter(Op.write, _path, changing: true);
    _fs.files[_path] = data;
  }

  @override
  Future<void> sync() => _fs._enter(Op.sync, _path);

  @override
  Future<void> close() => _fs._enter(Op.close, _path);
}

/// Waits that take no time, recorded: what a retry would have slept.
final class NoSleep {
  final List<int> slept = [];
  Future<void> call(int ms) async => slept.add(ms);
  int get total => slept.fold(0, (a, b) => a + b);
}

/// The default storage over `fs` at [statePath], its waits taking no time.
FileStorage memoryStorage(MemoryFs fs, [NoSleep? sleep]) => FileStorage.at(statePath, fs: fs, sleep: (sleep ?? NoSleep()).call);

/// A state from JSON.
StoredState state(Map<String, Object?> json) => StoredState.fromJson(json);

/// `latest` with `fields` set: a merge as a save makes one.
StoredState Function(StoredState latest) setting(Map<String, Object?> fields) =>
    (latest) => StoredState.fromJson({...latest.toJson(), ...fields});

/// Until `hold` is reached by `started`: fails with a sentence, not a hang,
/// when the call finishes first or never gets there.
Future<void> untilReached(Hold hold, String what, Future<Object?> started,
    {Duration within = const Duration(seconds: 4)}) async {
  Object? settled;
  var done = false;
  unawaited(started.then((_) => done = true, onError: (Object e) {
    done = true;
    settled = e;
  }));
  final deadline = DateTime.now().add(within);
  while (!hold.reached) {
    if (done) throw StateError('$what finished without reaching its held operation${settled == null ? '' : ': $settled'}');
    if (DateTime.now().isAfter(deadline)) throw StateError('$what never reached its held operation');
    await Future<void>.delayed(Duration.zero);
  }
}

/// A temp folder on this machine for one test, removed after it.
Future<void> inTemp(Future<void> Function(String dir) test) async {
  final dir = await Directory.systemTemp.createTemp('keygrant-');
  try {
    await test(dir.path);
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

/// `dir`'s entries by name, sorted.
List<String> namesIn(String dir) =>
    [for (final e in Directory(dir).listSync()) e.path.substring(e.path.lastIndexOf(sep) + 1)]..sort();

/// Write `text` to `path`, last modified `ageMs` ago when given.
Future<void> writeAged(String path, String text, [int? ageMs]) async {
  await File(path).writeAsString(text);
  if (ageMs != null) await File(path).setLastModified(DateTime.now().subtract(Duration(milliseconds: ageMs)));
}

/// A file's JSON.
Object? jsonAt(String path) => jsonDecode(File(path).readAsStringSync());
