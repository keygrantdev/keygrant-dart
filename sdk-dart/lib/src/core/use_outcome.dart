/// What a `use` answer does (the SDK contract, 12.6; meters.ts `useOutcome`).
library;

import 'http.dart';
import 'json.dart';
import 'lease.dart';
import 'meter_types.dart';
import 'meters.dart';
import 'offline.dart';
import 'stored_state.dart';
import 'types.dart';
import 'wire.dart';

/// What came of a `use` request.
enum UseOutcomeKind {
  spent('spent'),
  usedUp('used-up'),
  noMeter('no-meter'),
  refused('refused'),

  /// No usable answer: the spend comes from the offline allowance, in doubt when it was sent.
  unanswered('unanswered');

  const UseOutcomeKind(this.wire);
  final String wire;
}

/// What a `use` answer does: its outcome, the refusal of a verdict, the
/// answer's `left` for `used-up`, what is saved as the answer to the ask, the
/// figures saved and the reports it confirms.
final class UseOutcome {
  const UseOutcome(this.outcome, {this.refusal, this.left, this.patch = const {}, this.figures = const {}, this.confirmed = const []});

  final UseOutcomeKind outcome;
  final Refusal? refusal;
  final int? left;
  final StatePatch patch;
  final Map<String, MeterFigure> figures;
  final List<Confirmed> confirmed;

  Map<String, Object?> toJson() => withoutNulls({
        'outcome': outcome.wire,
        'refusal': refusal?.wire,
        'left': left,
        'patch': patch,
        'figures': figures.map((code, f) => MapEntry(code, f.toJson())),
        'confirmed': [for (final c in confirmed) c.toJson()],
      });
}

/// The figures a `use` answer gives, each stamped with the server's time
/// (`at`); none for an answer without a whole `at`.
Map<String, MeterFigure> _answeredFigures(Map<String, Object?>? body) {
  final at = figureOf(body?['at']);
  if (body == null || at == null) return const {};
  return metersOf(body['meters'])
      .map((code, m) => MapEntry(code, MeterFigure(left: m.left, total: m.total, offline: m.offline, resets: m.resets, at: at)));
}

/// What a `use` answer saves and says (12.6). `askedAt` is the device clock
/// when the request was made; `kind` and `ownClaim` who this device is.
UseOutcome useOutcome({
  required HttpResponse? response,
  required int askedAt,
  required int major,
  required DeviceKind? kind,
  required String? ownClaim,
}) {
  final keyed = keyedBy(kind);
  if (response == null) {
    return UseOutcome(UseOutcomeKind.unanswered,
        patch: {Field.backoffSince: askedAt, Field.backoffMs: retryUnansweredMs, ...keyed});
  }
  if (noAnswer(response.status)) return const UseOutcome(UseOutcomeKind.unanswered);
  final body = response.json is List ? null : asObject(response.json);
  if (response.status == 200) {
    if (body?['spent'] != true) return const UseOutcome(UseOutcomeKind.unanswered);
    return UseOutcome(UseOutcomeKind.spent, figures: _answeredFigures(body), confirmed: spendsConfirmed(response));
  }
  final error = errorOf(response.json);
  final confirmed = spendsConfirmed(response);
  if (error == 'used-up') {
    return UseOutcome(UseOutcomeKind.usedUp, left: figureOf(body?['left']), figures: _answeredFigures(body), confirmed: confirmed);
  }
  if (error == 'unknown-meter') return UseOutcome(UseOutcomeKind.noMeter, confirmed: confirmed);
  final refused = refusalOf(error);
  if (refused == null) return const UseOutcome(UseOutcomeKind.unanswered);
  final patch = {
    Field.checkedMajor: major,
    Field.backoffSince: askedAt,
    Field.backoffMs: askAgainMs,
    ...keyed,
    ...refusalPatch(refused, major, ownClaim),
  };
  return UseOutcome(UseOutcomeKind.refused, refusal: refused, patch: patch, confirmed: confirmed);
}
