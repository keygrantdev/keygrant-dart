/// The SDK's default state file (the SDK contract, section 6; storage.ts):
/// where it lives, and how it is read and written so that neither a crash nor
/// a busy disk ever costs a customer their licence.
library;

import 'dart:convert';
import 'dart:io';

import 'adapters.dart';
import 'stored_state.dart';
import 'storage_fs.dart';

export 'storage_fs.dart' show keepCorrupt, staleTempMs;

/// How many times a save is merged onto a state another process changed under it.
const int updateAttempts = 5;

/// Where the default storage keeps a product's state on Windows, macOS and
/// Linux: a folder of this user's on THIS machine, never one that roams:
/// `%LOCALAPPDATA%\KeyGrant` (else `~\AppData\Local\KeyGrant`),
/// `~/Library/Application Support/KeyGrant`, `$XDG_CONFIG_HOME/keygrant` (else
/// `~/.config/keygrant`). An empty or relative variable is taken as unset.
String defaultStoragePath(String product, {required String platform, required String home, required Map<String, String> env}) {
  final file = '$product.json';
  if (platform == 'win32') {
    final local = _absolute(env['LOCALAPPDATA'], windows: true) ?? '$home\\AppData\\Local';
    return '$local\\KeyGrant\\$file';
  }
  if (platform == 'darwin') return '$home/Library/Application Support/KeyGrant/$file';
  final config = _absolute(env['XDG_CONFIG_HOME'], windows: false) ?? '$home/.config';
  return '$config/keygrant/$file';
}

/// `value` when it is an absolute path (as Node's `win32.isAbsolute` or
/// `posix.isAbsolute` says), less any separators it ends with; else null.
String? _absolute(String? value, {required bool windows}) {
  if (value == null || value.isEmpty) return null;
  final absolute = windows ? RegExp(r'^([A-Za-z]:)?[\\/]').hasMatch(value) : value.startsWith('/');
  return absolute ? value.replaceFirst(RegExp(windows ? r'[\\/]+$' : r'/+$'), '') : null;
}

/// The folder a path is in, and its name: split at its last separator.
({String dir, String name}) splitPath(String path) {
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? (dir: '.', name: path) : (dir: path.substring(0, cut), name: path.substring(cut + 1));
}

const String _conflict = 'ECONFLICT';

/// JSON file storage. Read: only a MISSING file is no state (its newest whole
/// temp file read first); any other failure is tried again for about a second
/// and then throws; a file that does not parse is set aside as
/// `<file>.<ms>.corrupt` (the newest three kept) and an empty state written in
/// its place. Written atomically: a temp file beside it, flushed, renamed over
/// it (tried again when busy), the folder flushed after on POSIX. Each save
/// stamps `rev` one higher and checks just before the rename that the file's
/// `rev` is the one it read, merging again onto a newer state up to five times.
final class FileStorage extends StorageAdapter {
  /// Storage at the path `path` resolves to (resolved once, at the first read
  /// or write: a phone's support folder is asked for asynchronously).
  FileStorage(Future<String> Function() path, {StorageFs fs = const IoStorageFs(), Future<void> Function(int ms)? sleep})
      : _path = path,
        _fs = fs,
        _sleep = sleep ?? ((ms) => Future.delayed(Duration(milliseconds: ms)));

  /// Storage at `path`.
  FileStorage.at(String path, {StorageFs fs = const IoStorageFs(), Future<void> Function(int ms)? sleep})
      : this(() async => path, fs: fs, sleep: sleep);

  final Future<String> Function() _path;
  final StorageFs _fs;
  final Future<void> Function(int ms) _sleep;
  Future<String>? _resolved;

  /// The file's path, asked for once and kept; a failure is not kept, so the
  /// next call asks again (a phone's support folder may not be ready yet).
  Future<String> get _file => _resolved ??= _path().catchError((Object error) {
        _resolved = null;
        throw error;
      });

  Future<void> _place(StoredState state, [Future<void> Function()? allowed]) async {
    final path = await _file;
    final (:dir, :name) = splitPath(path);
    final temp = await writeTemp(_fs, dir, '$name.', state);
    try {
      await retrying(() async {
        await allowed?.call();
        await _fs.rename(temp, path);
      }, renameBackoffMs, busy, _sleep);
    } catch (_) {
      try {
        await _fs.rm(temp);
      } catch (_) {}
      rethrow;
    }
    try {
      await _fs.syncDir(dir);
    } catch (_) {}
    await clearStale(_fs, dir, '$name.');
  }

  @override
  Future<void> write(StoredState state) => _place(state);

  /// The state, and the revision of the FILE it was read from.
  Future<({StoredState? state, int? rev})> _loadState(bool readOnly) async {
    final path = await _file;
    final (:dir, :name) = splitPath(path);
    final text = await readText(_fs, path, _sleep);
    if (text == null) return (state: await leftover(_fs, dir, '$name.'), rev: null);
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      if (readOnly) return (state: null, rev: null);
      final aside = '$path.${DateTime.now().millisecondsSinceEpoch}.corrupt';
      await retrying(() => _fs.rename(path, aside), renameBackoffMs, busy, _sleep);
      try {
        await write(StoredState.empty);
      } catch (_) {}
      await pruneCorrupt(_fs, dir, '$name.');
      return (state: null, rev: null);
    }
    final state = json == null ? null : StoredState.fromJson(json);
    return (state: state, rev: state?.rev);
  }

  /// Throws a conflict when the file's revision is no longer `rev`.
  Future<void> _unchanged(int? rev) async {
    String? text;
    try {
      text = await _fs.readFile(await _file);
    } catch (error) {
      if (!missing(codeOf(error))) rethrow;
    }
    if (_revOf(text) == rev) return;
    throw const StorageFsException(_conflict, 'the state was saved by another process');
  }

  @override
  Future<StoredState?> read({bool readOnly = false}) async => (await _loadState(readOnly)).state;

  @override
  Future<void> update(StoredState Function(StoredState latest) merge) async {
    for (var attempt = 1;; attempt++) {
      final base = await _loadState(false);
      final next = merge(base.state ?? StoredState.empty).patched({Field.rev: (base.state?.rev ?? 0) + 1});
      try {
        return await _place(next, () => _unchanged(base.rev));
      } catch (error) {
        if (codeOf(error) != _conflict || attempt >= updateAttempts) rethrow;
      }
    }
  }
}

/// The revision a file's text carries: none when missing or unstamped; a
/// marker equal to none when it does not parse.
Object? _revOf(String? text) {
  if (text == null) return null;
  try {
    return StoredState.fromJson(jsonDecode(text)).rev;
  } on FormatException {
    return double.nan;
  }
}

/// Whether this process runs on a desktop system the contract's section 6 names.
bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
