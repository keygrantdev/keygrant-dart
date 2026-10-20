/// Metered uses, decided without I/O (the SDK contract, section 12; meters.ts):
/// what `use()` may ask for, whether it asks now, what an answer does, what a
/// device may spend while it gets none, the figures a status shows, and what
/// the journal reports and the server's answers confirm of it.
library;

import 'dart:math' as math;

import 'http.dart';
import 'json.dart';
import 'jws.dart';
import 'lease.dart';
import 'meter_types.dart';
import 'offline.dart';
import 'stored_state.dart';
import 'types.dart';
import 'wire.dart';

/// The most uses one meter may count.
const int maxMeterUses = 1000000000;

/// The most entries the journal holds, and a report carries.
const int maxPendingSpends = 64;

/// The most `void` entries the journal holds.
const int maxPendingVoids = 16;

/// How long an entry is kept unreported (ms): twice the longest lease.
const int pendingMaxMs = 180 * 86400000;

/// How long a `use` request may take (ms), or the HTTP bound when that is shorter.
const int useTimeoutMs = statusCheckTimeoutMs;

/// The longest meter code a call may name, in UTF-16 units.
const int maxMeterCode = 32;

/// What `use(meter, n)` asks for, or why it asks nothing: the amount is judged
/// before the code (`askedFor`). [refused] is `invalid-amount` or `no-meter`.
final class AskedFor {
  const AskedFor._(this.meter, this.n, this.refused);
  final String? meter;
  final int? n;
  final UseError? refused;

  Map<String, Object?> toJson() => refused != null ? {'refused': refused!.wire} : {'meter': meter, 'n': n};
}

AskedFor askedFor(String meter, [int n = 1]) {
  if (n < 1 || n > maxMeterUses) return const AskedFor._(null, null, UseError.invalidAmount);
  if (meter.isEmpty || meter.length > maxMeterCode) return const AskedFor._(null, null, UseError.noMeter);
  return AskedFor._(meter, n, null);
}

/// A spend's id: 16 bytes from the platform's secure random source, base64url
/// with no padding (22 characters), never reused.
String newSpendId() {
  final random = math.Random.secure();
  return b64urlEncode([for (var i = 0; i < 16; i++) random.nextInt(256)]);
}

/// Uses this device spent that KeyGrant has not heard of: the `n` of a meter's
/// `offline` and `unanswered` entries, never a `void`.
int unsyncedOf(List<SpendEntry> spends, String meter) =>
    spends.fold(0, (sum, e) => e.meter == meter && !e.isVoid ? sum + e.n : sum);

/// The base figures of each meter: its stored figure when at or after the
/// lease's own second (`iat`, seconds), else the lease's `met` member, else none.
Map<String, BaseFigure> figuresOf(Map<String, MeterClaim>? met, int iat, Map<String, MeterFigure> stored) {
  final leased = met ?? const {};
  final base = <String, BaseFigure>{};
  for (final code in {...leased.keys, ...stored.keys}) {
    final answer = stored[code];
    final figure = answer != null && answer.at >= iat * 1000 ? answer.base : leased[code];
    if (figure != null) base[code] = figure;
  }
  return base;
}

/// The base figures of the lease that licenses this device and the answers stored beside it.
Map<String, BaseFigure> figuresFor(LeaseClaims claims, StoredState state) => figuresOf(claims.met, claims.iat, state.meterFigures);

/// `status().meters`: each meter with base figures, its `left` net of this
/// device's unsynced spends and never below 0.
Map<String, MeterStatus> meterStatusOf(Map<String, BaseFigure> figures, List<SpendEntry> spends) => {
      for (final MapEntry(key: code, value: f) in figures.entries)
        code: MeterStatus(
          left: math.max(0, f.left - unsyncedOf(spends, code)),
          total: f.total,
          offline: f.offline,
          unsynced: unsyncedOf(spends, code),
          resets: f.resets,
        ),
    };

/// Whether a spend with no answer is allowed (12.7): allowed with what is left
/// and its `limit`, or `no-meter`, or `offline-limit` with what is left.
final class OfflineSpend {
  const OfflineSpend._(this.ok, this.left, this.limit, this.error);
  final bool ok;
  final int? left;
  final int? limit;
  final UseError? error;

  Map<String, Object?> toJson() => withoutNulls({'ok': ok, 'error': error?.wire, 'left': left, 'limit': limit});
}

OfflineSpend offlineSpend(Map<String, BaseFigure> figures, List<SpendEntry> spends, String meter, int n) {
  final f = figures[meter];
  if (f == null) return const OfflineSpend._(false, null, null, UseError.noMeter);
  final unsynced = unsyncedOf(spends, meter);
  final left = math.max(0, f.left - unsynced);
  if (unsynced + n <= f.offline && n <= left) return OfflineSpend._(true, left - n, math.min(f.offline, f.left), null);
  return OfflineSpend._(false, left, null, UseError.offlineLimit);
}

/// Whether the journal's wait runs at `now` (the guarded clock): with k
/// `unanswered` and `void` entries opened at or before `now`, until
/// `min(ASK_AGAIN_MS, RETRY_UNANSWERED_MS x 2^(k-1))` after the newest of them.
bool journalWaiting(List<SpendEntry> spends, int now) {
  final opened = [for (final e in spends) if (e.kind != SpendKind.offline && e.at <= now) e];
  if (opened.isEmpty) return false;
  final newest = opened.map((e) => e.at).reduce(math.max);
  final wait = opened.length >= 7 ? askAgainMs : math.min(askAgainMs, retryUnansweredMs * (1 << (opened.length - 1)));
  return now < newest + wait;
}

/// Whether the wait of an uncovered spend runs: a `void` opened less than
/// RETRY_UNANSWERED_MS before `now`, at or before both clocks.
bool voidWaiting(List<SpendEntry> spends, int now, int clockNow) =>
    spends.any((e) => e.isVoid && e.at <= now && e.at <= clockNow && now < e.at + retryUnansweredMs);

/// Whether `use()` asks the server (12.5).
bool useAsksNow({required StoredState state, required int clockNow, required int now, required bool covered}) {
  final spends = state.spends;
  if (!covered) return !voidWaiting(spends, now, clockNow);
  final since = state.backoffSince, ms = state.backoffMs;
  final waiting = since != null && ms == retryUnansweredMs && clockNow >= since && clockNow < since + retryUnansweredMs;
  return !waiting && !journalWaiting(spends, now);
}

/// Whether the journal makes `status()` ask a valid lease's server now: it
/// holds an entry and its wait is not running.
bool journalAsks(List<SpendEntry> spends, int now) => spends.isNotEmpty && !journalWaiting(spends, now);

/// The report a body carries: the journal's entries, oldest first, at most
/// [maxPendingSpends], a void marked; null for an empty journal.
List<Map<String, Object?>>? spendsReported(List<SpendEntry> spends) {
  final report = [
    for (final e in spends.take(maxPendingSpends))
      {'id': e.id, 'meter': e.meter, 'n': e.n, 'at': e.at, if (e.isVoid) 'void': true},
  ];
  return report.isEmpty ? null : report;
}

/// The reports an answer names as recorded, read leniently. No answer at all,
/// a 5xx and a 429 confirm nothing.
List<Confirmed> spendsConfirmed(HttpResponse? response) {
  if (response == null || noAnswer(response.status)) return const [];
  final listed = (response.json is List ? null : asObject(response.json))?['spends'];
  if (listed is! List) return const [];
  final confirmed = <Confirmed>[];
  for (final member in listed) {
    final m = member is List ? null : asObject(member);
    final id = m?['id'];
    if (m == null || id is! String) continue;
    final n = safeWholeOf(m['n']);
    if (m['void'] == true) {
      confirmed.add(Confirmed.voided(id));
    } else if (n != null && n >= 1) {
      confirmed.add(Confirmed.count(id, n));
    }
  }
  return confirmed;
}
