// Helpers for the trial, deactivate, one-call-at-a-time and two-instance
// suites: trial leases and answers, short bounds, a fingerprinter that never
// answers, and an in-memory file system under the default file storage.

import 'dart:async';
import 'dart:convert';

import 'package:keygrant/keygrant.dart';
import 'package:keygrant/src/core/engine_timing.dart';
import 'package:keygrant/src/core/storage_fs.dart';

import 'harness.dart';

/// The SDK's own bounds, cut short: a call behind a stuck one waits for the
/// HTTP bound (set per harness) plus 300 ms.
const Timing quick = Timing(
  lockGrace: Duration(milliseconds: 300),
  statusCheck: Duration(milliseconds: 300),
  machineId: Duration(milliseconds: 200),
  activateMachineId: Duration(milliseconds: 400),
  identifySlack: Duration(milliseconds: 50),
);

/// The HTTP bound the stall suites use with [quick].
const Duration quickHttp = Duration(milliseconds: 200);

/// A trial lease for the harness device, signed at `at` for `days` days.
Future<String> trialLeaseOf(Signer signer, {int days = 5, int at = now0, Map<String, Object?> ent = const {}}) =>
    signer.lease('trial:fp-test', model: 'trial', ttlSeconds: days * 86400, at: at, extra: {'ent': ent});

/// The server answers `trial` with this trial.
void answersTrial(Harness h, {required int start, required int ends, String? lease}) =>
    h.http.on('trial', (_) => HttpResponse(200, {'trialStart': start, 'trialEndsAt': ends, if (lease != null) 'lease': lease}));

/// A running trial's status: `days` left, ending `days` days from now0.
LicenseStatus trialFor(int days, {bool stalled = false}) =>
    LicenseStatus(LicenseState.trial, trialEndsAt: now0 + days * day, trialDaysLeft: days, stalled: stalled);

const LicenseStatus trialOver = LicenseStatus(LicenseState.expired, reason: LicenseReason.trial);

/// A licensed status for `key1`.
LicenseStatus licensedStatus({bool stalled = false}) => LicenseStatus(LicenseState.licensed, key: key1, stalled: stalled);

/// The stored JSON of a running trial of five days, started two days ago.
Future<Map<String, Object?>> runningTrial(Signer signer, [Map<String, Object?> more = const {}]) async => {
      'trialStart': now0 - 2 * day,
      'trialEndsAt': now0 + 5 * day,
      'trialLease': await trialLeaseOf(signer),
      'lastSeen': now0,
      ...more,
    };

/// The stored JSON of a licence of `key1` on a lease valid for 30 days.
Future<Map<String, Object?>> licensedJson(Signer signer, [Map<String, Object?> more = const {}]) async => {
      'key': key1,
      'activationId': 'act_1',
      'lease': await signer.lease(key1),
      'checkedMajor': 1,
      'lastSeen': now0,
      ...more,
    };

/// Store `json` in the harness.
void storeJson(Harness h, Map<String, Object?> json) => h.stored = StoredState.fromJson(json);

int posts(Harness h, String action) => h.http.count(action);

/// A fingerprinter whose `get()` never answers; counts the reads.
final class StuckFingerprinter extends Fingerprinter {
  int reads = 0;
  final List<({int count, Completer<void> done})> _waiting = [];

  @override
  Future<String> get() {
    reads++;
    _waiting.removeWhere((w) {
      if (w.count > reads) return false;
      w.done.complete();
      return true;
    });
    return Completer<String>().future;
  }

  Future<void> whenRead([int n = 1]) {
    if (reads >= n) return Future.value();
    final done = Completer<void>();
    _waiting.add((count: n, done: done));
    return done.future;
  }
}

/// A fingerprinter whose `identify` answers `identity`.
final class IdentityFingerprinter extends Fingerprinter {
  const IdentityFingerprinter(this.identity);
  final DeviceIdentity identity;
  @override
  Future<String> get() async => identity.fingerprint ?? 'unused';
  @override
  Future<DeviceIdentity> identify(Duration timeout) async => identity;
}

/// A fingerprinter that cannot read the device.
final class FailingFingerprinter extends Fingerprinter {
  const FailingFingerprinter();
  @override
  Future<String> get() async => throw StateError('the machine id cannot be read just now');
}

/// How long `future` takes, in ms.
Future<(T, int)> timed<T>(Future<T> future) async {
  final watch = Stopwatch()..start();
  final value = await future;
  return (value, watch.elapsedMilliseconds);
}

/// Whether `future` has completed after `wait`.
Future<bool> settledWithin(Future<Object?> future, Duration wait) async {
  var settled = false;
  unawaited(future.then((_) => settled = true, onError: (_) => settled = true));
  await Future<void>.delayed(wait);
  return settled;
}

/// A file system in memory, as the default file storage sees one. Paths are
/// kept with forward slashes. `holdNext('create')` holds the next temp file
/// created until released.
final class MemoryFs implements StorageFs {
  final Map<String, String> files = {};
  final List<String> ops = [];
  ({Completer<void> reached, Completer<void> release})? _hold;

  static String _norm(String path) => path.replaceAll('\\', '/');

  /// The next `create` waits until the returned release is called; `reached` completes when it is made.
  ({Future<void> reached, void Function() release}) holdNextCreate() {
    final hold = (reached: Completer<void>(), release: Completer<void>());
    _hold = hold;
    return (reached: hold.reached.future, release: hold.release.complete);
  }

  @override
  Future<String> readFile(String path) async {
    final text = files[_norm(path)];
    if (text == null) throw const StorageFsException('ENOENT');
    return text;
  }

  @override
  Future<StorageFile> create(String path) async {
    final p = _norm(path);
    ops.add('create $p');
    final hold = _hold;
    if (hold != null) {
      _hold = null;
      hold.reached.complete();
      await hold.release.future;
    }
    if (files.containsKey(p)) throw const StorageFsException('EEXIST');
    files[p] = '';
    return _MemoryFile(this, p);
  }

  @override
  Future<void> rename(String from, String to) async {
    final text = files.remove(_norm(from));
    if (text == null) throw const StorageFsException('ENOENT');
    files[_norm(to)] = text;
  }

  @override
  Future<void> rm(String path) async => files.remove(_norm(path));

  @override
  Future<List<String>> readdir(String dir) async {
    final prefix = '${_norm(dir)}/';
    return [for (final p in files.keys) if (p.startsWith(prefix)) p.substring(prefix.length)];
  }

  @override
  Future<int> mtimeMs(String path) async => DateTime.now().millisecondsSinceEpoch;

  @override
  Future<void> mkdir(String dir) async {}

  @override
  Future<void> syncDir(String dir) async {}
}

final class _MemoryFile implements StorageFile {
  _MemoryFile(this._fs, this._path);
  final MemoryFs _fs;
  final String _path;
  @override
  Future<void> write(String data) async => _fs.files[_path] = (_fs.files[_path] ?? '') + data;
  @override
  Future<void> sync() async {}
  @override
  Future<void> close() async {}
}

const String statePath = '/state/sluice.json';

/// One state file in memory holding `json`.
MemoryFs oneFile(Map<String, Object?> json) => MemoryFs()..files[statePath] = jsonEncode(json);

/// The state saved in `fs`.
Map<String, Object?> savedIn(MemoryFs fs) => jsonDecode(fs.files[statePath]!) as Map<String, Object?>;

/// An instance of the app over `fs`, its clock at `now`, its server answering each action as `answers` says.
KeyGrantLicense instanceOver(MemoryFs fs, Signer signer,
    {required int now, Map<String, HttpResponse> answers = const {}, Fingerprinter? fingerprinter, int major = 1}) {
  final http = FakeHttp();
  for (final MapEntry(key: action, value: answer) in answers.entries) {
    http.on(action, (_) => answer);
  }
  final clock = FakeClock()..value = now;
  return KeyGrantLicense(LicenseConfig(
    product: product,
    apiBaseUrl: 'https://api.test',
    publicJwk: signer.publicJwk,
    major: major,
    adapters: LicenseAdapters(
      storage: FileStorage.at(statePath, fs: fs, sleep: (_) async {}),
      registry: FakeStash(),
      clock: clock,
      fingerprinter: fingerprinter ?? const PlainFingerprinter(),
      http: http,
    ),
  ));
}

/// `first` held at its first save until `between` has run, then let finish.
Future<T> interleave<T>(MemoryFs fs, Future<T> Function() first, Future<void> Function() between) async {
  final hold = fs.holdNextCreate();
  final running = first();
  await hold.reached.timeout(const Duration(seconds: 10));
  await between();
  hold.release();
  return running;
}
