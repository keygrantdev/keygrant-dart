/// The licence an app holds (the SDK contract, sections 5 and 8; license.ts).
library;

import 'dart:async';

import 'package:meta/meta.dart' show visibleForTesting;

import '../adapters.dart';
import '../clock.dart';
import '../defaults.dart';
import '../device.dart';
import '../engine_timing.dart';
import '../entitlements.dart';
import '../http.dart';
import '../journal.dart';
import '../json.dart';
import '../keys.dart';
import '../lease.dart';
import '../license_file.dart';
import '../link.dart';
import '../merge.dart';
import '../meter_types.dart';
import '../meters.dart';
import '../offline.dart';
import '../pickup.dart';
import '../renewal.dart';
import '../results.dart';
import '../status.dart';
import '../stored_state.dart';
import '../text.dart';
import '../types.dart';
import '../use_outcome.dart';
import '../wire.dart';

part 'checkin.dart';
part 'engine.dart';
part 'files.dart';
part 'pickup_engine.dart';
part 'seats.dart';
part 'spend.dart';
part 'status_now.dart';
part 'trials.dart';

/// Client-side licensing for an app. Verifies signed leases OFFLINE and only
/// contacts KeyGrant to activate, to renew a lease nearing its end or past it,
/// to tell it of a newer major, to spend a metered use or report the uses this
/// device spent with no answer, or (at most once a day, in the background) to
/// report a running trial's launch: so an outage, no network, a 5xx, a 429, an
/// ambiguous 4xx or an unusable answer never locks out a paying customer while
/// their lease is valid. Only an explicit verdict from the server, or the
/// lease's own end, does.
///
/// Calls on one licence run one at a time; make one per app and share it.
/// `status()`, `refresh()`, `startTrial()`, `has()`, `use()` and the pickup
/// calls never throw for storage or the network; `activate()` throws only when
/// the state cannot be read or saved; `deactivate()`, `importLicenseFile()` and
/// `removeLicenseFile()` throw [LicenseCallUnfinished] behind a call that has
/// not finished, and the storage's error when the state cannot be saved.
final class KeyGrantLicense extends _StatusEngine {
  /// A licence for `config.product`. Throws a [LicenseConfigError] when the
  /// configuration cannot be used (no public key, both key members, a key that
  /// is not an Ed25519 public JWK), so it is found the first time the app runs.
  KeyGrantLicense(LicenseConfig config) : super(config, Timing.standard);

  /// A licence whose own time bounds are `timing`: for tests.
  @visibleForTesting
  KeyGrantLicense.timed(super.config, super.timing);

  /// Activate a licence key on this device. The key is trimmed and upper-cased
  /// first. A user-locked key asks a NEW device who it is: `email` is the
  /// address the key was sold to and, for a key that mails a code, `code` is
  /// the code that came. Neither is stored. An address longer than any, or a
  /// code that is not six digits, is refused here for any key.
  Future<ActivateResult> activate(String key, {String? email, String? code}) =>
      _serial((readOnly) async => readOnly ? const ActivateFailed(LicenseError.network) : _activateNow(key, email: email, code: code));

  /// The licence's status, offline-first (5.2): it asks the server only when
  /// it should, each at most once per wait unless `forceOnline`. Never throws:
  /// a state that cannot be read just now is `unknown` / `storage`.
  Future<LicenseStatus> status({bool forceOnline = false}) => _serial((readOnly) async {
        if (!readOnly) {
          await _saveUnsavedTrial();
          await _saveUnsavedJournal();
        }
        final state = await _loadForStatus(readOnly);
        final status = state == null ? _unreadable : await _statusNow(state, forceOnline, readOnly);
        return readOnly ? status.asStalled() : status;
      });

  /// `status()` forced online, whatever the waits say: call it when the
  /// customer says they have paid, or on a "Try again" of a lockout screen.
  Future<LicenseStatus> refresh() => status(forceOnline: true);

  /// Whether the licence this device holds grants the entitlement `code`: a
  /// flag that is on, a number that is not zero, or a text that is not empty.
  /// Offline, from what is stored only, as `status()` judges it with no ask and
  /// no write. A state that cannot be read grants nothing just now.
  Future<bool> has(String code) async => grants((await _storedStatus()).entitlements, code);

  /// As [has], but throwing [MissingEntitlement], which names `code`, when the
  /// licence does not grant it.
  Future<void> require(String code) async {
    if (!await has(code)) throw MissingEntitlement(code);
  }

  /// Release this device's activation and drop the local licence, keeping the
  /// trial evidence; [DeactivateResult.released] says whether the seat is now
  /// free. Another device's seat is never released: an activation stored here
  /// that is another device's is only dropped.
  Future<DeactivateResult> deactivate() => _serial((readOnly) {
        if (readOnly) throw const LicenseCallUnfinished();
        return _deactivateNow();
      });

  /// Begin (or re-sync) a trial for this device. Never throws: `unknown` when
  /// the state cannot be read, and the server's trial when it cannot be saved.
  Future<LicenseStatus> startTrial() => _serial((readOnly) async {
        final state = await _loadForStatus(readOnly);
        if (state == null) return readOnly ? _unreadable.asStalled() : _unreadable;
        if (!readOnly) return _startTrialNow(state);
        return (await _trialStatus(state, _effectiveNow(state))).asStalled();
      });

  /// `paymentLink` with this device's ACTIVATION id (never the key) as its one
  /// `client_reference_id`, or null when the device holds no activated licence.
  /// Throws an [ArgumentError] for a link that is not an absolute URL.
  Future<String?> upgradeUrl(String paymentLink) async {
    // Read-only: this runs outside the one-at-a-time order, beside any call.
    final state = await _load(true);
    final key = state.key, activationId = state.activationId;
    if (key == null || key.isEmpty || activationId == null || activationId.isEmpty) return null;
    final link = referencedLink(paymentLink, activationId);
    if (link == null) throw ArgumentError.value(paymentLink, 'paymentLink', 'not an absolute URL');
    return link;
  }

  /// Spend `n` (default 1) uses of the key's meter `meter`, before the work
  /// they count; do the work only on [UseSpent]. Online it is exact; with no
  /// answer it spends from this device's offline allowance and reports the
  /// spend later. Never throws. Two calls are two spends.
  Future<UseResult> use(String meter, [int n = 1]) => _useMeter(meter, n);

  /// Take a licence file the customer was sent (`.kglicense`), as text: an
  /// offline file is stored and licenses the app with no network, ever; a key
  /// file's key is activated as `activate()` would, with `email` and `code` for
  /// a user-locked key. Throws [LicenseCallUnfinished] behind a call that has
  /// not finished, and the storage's error when it cannot be saved.
  Future<ImportLicenseFileResult> importLicenseFile(String text, {String? email, String? code}) =>
      _import(text, email, code);

  /// [importLicenseFile] for the file's bytes, as a drop handler or an open
  /// dialog reads them.
  Future<ImportLicenseFileResult> importLicenseFileBytes(List<int> bytes, {String? email, String? code}) =>
      _import(bytes, email, code);

  Future<ImportLicenseFileResult> _import(Object content, String? email, String? code) => _serial((readOnly) {
        if (readOnly) throw const LicenseCallUnfinished();
        return _importFile(content, (key) => _activateNow(key, email: email, code: code));
      });

  /// Drop the stored offline licence file, if any; a key this device holds
  /// keeps working.
  Future<void> removeLicenseFile() => _serial((readOnly) {
        if (readOnly) throw const LicenseCallUnfinished();
        return _removeFile();
      });

  /// Key pickup (section 13), for a build that may not take a typed key (an
  /// App Store build): ask KeyGrant to mail a code to `email`, answered the
  /// same whether or not it holds a key of the product. Writes nothing.
  Future<PickUpSendResult> pickUp(String email) => _requestPickup(email);

  /// The address's live keys of the product for the code that came, for the
  /// app to let the customer pick one by its model (never shown as a key).
  /// Writes nothing; the keys are kept in memory for ten minutes, so a
  /// `restoreByEmail` with the same code asks nothing more.
  Future<PickUpKeysResult> confirmPickUp(String email, String code) => _confirmPickup(email, code);

  /// Confirm the code and activate, on this device, the key of the address
  /// that fits this build (the one it holds a seat on, else one with a free
  /// seat, else the first). The key is never handed to the app.
  Future<RestoreResult> restoreByEmail(String email, String code) =>
      _serial((readOnly) async => readOnly ? const RestoreFailed(RestoreError.network) : _restoreNow(email, code));

  /// Completes once the launch report in flight, if any, has: for tests.
  @visibleForTesting
  Future<void> launchReportSettled() => _launch;
}

const LicenseStatus _unreadable = LicenseStatus(LicenseState.unknown, reason: LicenseReason.storage);
