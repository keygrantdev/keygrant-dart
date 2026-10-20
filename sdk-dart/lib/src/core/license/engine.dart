part of 'license.dart';

/// The machinery under [KeyGrantLicense] (engine.ts): the adapters, one call
/// at a time, every request bounded, and the stored state with its clock
/// guard and its journal of unsynced spends.
abstract class _Engine {
  _Engine(LicenseConfig config, this._timing)
      : _product = config.product,
        _base = config.apiBaseUrl.endsWith('/')
            ? config.apiBaseUrl.substring(0, config.apiBaseUrl.length - 1)
            : config.apiBaseUrl,
        _major = majorOf(config.major),
        _keys = _keysOf(config),
        _httpTimeout = config.httpTimeout,
        _deviceHold = config.deviceHold,
        _storage = config.adapters.storage ?? defaultStorage(config.product),
        _registry = config.adapters.registry ?? defaultRegistry(config.product),
        _clock = config.adapters.clock ?? const SystemClock(),
        _http = config.adapters.http ?? PackageHttp() {
    _reader = DeviceIdentityReader(config.adapters.fingerprinter ?? defaultFingerprinter(config.product),
        slack: _timing.identifySlack);
  }

  final String _product;
  final String _base;
  final int _major;
  final List<VerifyingKey> _keys;
  final Duration _httpTimeout;
  final bool _deviceHold;
  final StorageAdapter _storage;
  final RegistryStash _registry;
  final LicenseClock _clock;
  final HttpAdapter _http;
  final Timing _timing;
  late final DeviceIdentityReader _reader;

  /// The last call queued: when it started running (with its grace), and when it settled.
  ({Future<Future<void>> started, Future<void> settled}) _last =
      (started: Future.value(Future<void>.value()), settled: Future<void>.value());

  /// Calls running with writes allowed that have not settled yet.
  int _writing = 0;

  /// Journal changes this process could not save, kept for the process.
  List<JournalOp> _unsaved = [];

  /// The views [_load] made with [_unsaved] landed on them, by their journal.
  final Expando<bool> _carrying = Expando('carrying');

  /// Saves in flight: while one is, [_unsaved] is only added to, never folded.
  int _saving = 0;

  /// Run `work` once every call before it has finished, but not past that
  /// call's HTTP bound + the lock grace from when it STARTED: then READ-ONLY
  /// (no ask, no write) for as long as any call before it is unsettled.
  Future<T> _serial<T>(Future<T> Function(bool readOnly) work) {
    final prev = _last;
    final started = Completer<Future<void>>();
    final run = () async {
      final graceOver = await prev.started;
      await Future.any([prev.settled, graceOver]);
      final readOnly = _writing > 0;
      if (!readOnly) _writing++;
      final grace = _Grace(_httpTimeout + _timing.lockGrace);
      started.complete(grace.over);
      try {
        return await work(readOnly);
      } finally {
        if (!readOnly) _writing--;
        grace.cancel();
      }
    }();
    _last = (started: started.future, settled: run.then((_) {}, onError: (Object _) {}));
    return run;
  }

  /// POST to the product's endpoint, ALWAYS bounded: by `timeout`, else by the
  /// configured HTTP bound, given to the adapter and kept by the SDK itself.
  Future<HttpResponse> _post(String action, Map<String, Object?> body, [Duration? timeout]) {
    final bound = timeout ?? _httpTimeout;
    return _http.post('$_base/v1/products/$_product/$action', body, timeout: bound).timeout(bound);
  }

  /// `bound`, or the configured HTTP bound when that is shorter.
  Duration _boundedBy(Duration bound) => bound < _httpTimeout ? bound : _httpTimeout;

  Future<VerifyResult> _verify(String lease, int now) => verifyLease(lease, _keys, now);

  /// The ids of the keys this build carries, in the order configured.
  List<String> get _keyIds => [for (final k in _keys) k.kid];

  /// A licence lease verified offline and held to this product, build, holder and device.
  Future<LeaseCheck> _evaluate(String lease, int now, {String? key, String? activationId, DeviceKind? deviceKind}) async {
    final device = await _device(_timing.machineId, deviceKind);
    final holder = LeaseHolder(key: key ?? '', activationId: activationId ?? '', claims: device.claims, canTell: device.canTell);
    return checkLease(await _verify(lease, now), _product, _major, holder);
  }

  /// A trial lease verified offline for this product and device.
  Future<TrialLease> _trialLease(String lease, int now, DeviceKind? installKind) async {
    final device = await _device(_timing.machineId, installKind);
    return trialLeaseOf(await _verify(lease, now), _product, device.claims, device.canTell);
  }

  /// Who this device is, read for at most about `timeout`, on an install keyed as `installKind`.
  Future<Device> _device(Duration timeout, DeviceKind? installKind) => _reader.read(timeout, installKind, _deviceHold);

  /// The install's kind as it bears on this device: none when nothing is held.
  DeviceKind? _installKind(DeviceKind? stored) => _deviceHold ? stored : null;

  Future<StoredState> _stored([bool readOnly = false]) async => await _storage.read(readOnly: readOnly) ?? StoredState.empty;

  bool _carried(StoredState view) {
    final spends = view.fields[Field.spends];
    return spends != null && _carrying[spends] == true;
  }

  /// The journal a request reports for `view`: as stored, with what this
  /// process holds in memory that opens an entry of its own (an `unanswered`
  /// spend and a `void`) and the confirmations it holds; an `offline` spend
  /// held in memory is withheld until it has landed (journal.ts `reportable`).
  Future<List<SpendEntry>> _reportable(StoredState view) async {
    if (!_carried(view) && _unsaved.isEmpty) return view.spends;
    final StoredState stored;
    try {
      stored = await _stored(true);
    } catch (_) {
      return const [];
    }
    if (stored.activationId != view.activationId) return const [];
    final held = [
      for (final op in _unsaved)
        if (op.kind == JournalOpKind.unanswered || op.kind == JournalOpKind.void_ || op.kind == JournalOpKind.confirmed) op,
    ];
    return landJournal(stored, held, guardedNow(_clock.now(), stored.lastSeen)).state.spends;
  }

  /// The stored state with the journal changes this process could not save landed on it.
  Future<StoredState> _load([bool readOnly = false]) async {
    final state = await _stored(readOnly);
    if (_unsaved.isEmpty) return state;
    final landed = landJournal(state, _unsaved, guardedNow(_clock.now(), state.lastSeen)).state;
    final spends = landed.fields[Field.spends];
    if (spends != null) _carrying[spends] = true;
    return landed;
  }

  /// Persist a patch onto the state as stored NOW (merge.ts `merged`), and
  /// advance the clock guard unless `guard` brings it back.
  Future<void> _save(StatePatch patch, [int? guard, Basis basis = const Basis()]) async {
    await _saveWith(patch, guard, basis, const []);
  }

  /// [_save] with changes to the journal, landed after the ones this process
  /// could not save before. Whether each of `ops` was refused. Throws when the
  /// save fails; the changes stay in memory until one lands.
  Future<List<bool>> _saveWith(StatePatch patch, int? guard, Basis basis, List<JournalOp> ops) async {
    final before = _unsaved.length;
    final all = [..._unsaved, ...ops];
    var refused = <bool>[];
    StoredState merge(StoredState latest) {
      final clockNow = _clock.now();
      final landed = landJournal(latest, all, guardedNow(clockNow, latest.lastSeen));
      refused = landed.refused;
      return merged(landed.state, patch, basis).patched({Field.lastSeen: savedLastSeen(latest.lastSeen, clockNow, guard)});
    }

    _saving++;
    try {
      await _storage.update(merge);
    } finally {
      _saving--;
    }
    _unsaved = _unsaved.sublist(before);
    return refused.sublist(before);
  }

  /// [_saveWith], whose failure fails nothing: what it could not save is kept
  /// in memory, those the journal had room for (judged on `view`).
  Future<List<bool>> _saveOps(StoredState view, StatePatch patch, Basis basis, List<JournalOp> ops) async {
    try {
      return await _saveWith(patch, null, basis, ops);
    } catch (_) {
      return _keepUnsaved(view, ops);
    }
  }

  /// Keep `ops` in memory, those the journal has room for on `view`. A spend
  /// is told to the customer from here on.
  List<bool> _keepUnsaved(StoredState view, List<JournalOp> ops) {
    final refused = landJournal(view, ops, guardedNow(_clock.now(), view.lastSeen)).refused;
    for (var i = 0; i < ops.length; i++) {
      if (refused[i]) continue;
      final op = ops[i];
      _unsaved.add(op.kind == JournalOpKind.offline || op.kind == JournalOpKind.unanswered ? op.asTold() : op);
    }
    if (_saving == 0) _unsaved = boundedVoids(compacted(_unsaved));
    return refused;
  }

  /// Save what this process could not, best-effort.
  Future<void> _saveUnsavedJournal() async {
    if (_unsaved.isNotEmpty) await _saveBestEffort(const {});
  }

  /// A save whose failure fails nothing. Whether it was saved.
  Future<bool> _saveBestEffort(StatePatch patch, [int? guard, Basis basis = const Basis()]) async {
    try {
      await _save(patch, guard, basis);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Never earlier than the highest wall-clock ever seen.
  int _effectiveNow(StoredState state) => guardedNow(_clock.now(), state.lastSeen);

  /// `now` for judging a lease the server has just signed, with the clock
  /// guard reconciled to it (clock.ts `clockCorrection`).
  Future<int> _serverNow(String lease, String key, String activationId,
      [Future<void> Function(StatePatch patch, int? guard)? save]) async {
    final stored = await _load();
    final now = _effectiveNow(stored);
    final claims = (await _verify(lease, now)).claims;
    final held = stored.lease;
    final heldIat = held == null ? null : (await _verify(held, now)).claims?.iat;
    final corrected = clockCorrection(
      clockNow: _clock.now(),
      lastSeen: stored.lastSeen,
      claims: claims == null ? null : SignedAt(sub: claims.sub, aid: claims.aid, iat: claims.iat),
      heldIat: heldIat,
      key: key,
      activationId: activationId,
    );
    if (corrected == null) return now;
    await (save ?? (patch, guard) => _save(patch, guard))(const {}, corrected);
    return corrected;
  }
}

/// A call's grace: over when its time is up, or as soon as the call settles.
final class _Grace {
  _Grace(Duration duration) {
    _timer = Timer(duration, _end);
  }

  final Completer<void> _over = Completer();
  late final Timer _timer;

  Future<void> get over => _over.future;

  void _end() {
    if (!_over.isCompleted) _over.complete();
  }

  void cancel() {
    _timer.cancel();
    _end();
  }
}

/// The key set a configuration gives: [LicenseConfig.publicJwks], or
/// [LicenseConfig.publicJwk] as a set of one. Neither, both, an empty set, or
/// a key that is not an Ed25519 public JWK throws a [LicenseConfigError].
List<VerifyingKey> _keysOf(LicenseConfig config) {
  final one = config.publicJwk, set = config.publicJwks;
  if (one != null && set != null) throw LicenseConfigError('give publicJwks or publicJwk, not both');
  final keys = set ?? [if (one != null) one];
  if (keys.isEmpty) throw LicenseConfigError('give the product\'s public keys (publicJwks)');
  for (var i = 0; i < keys.length; i++) {
    try {
      publicKeyBytes(keys[i]);
    } on LicenseConfigError catch (e) {
      throw LicenseConfigError('public key ${i + 1} cannot be used: ${e.message}');
    }
  }
  return importVerifyingKeys(keys);
}
