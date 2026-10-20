// How the harness reads a vector's inputs into the SDK's own types, as
// the reference's replay.ts reads them for the reference.

import 'package:keygrant/src/core/http.dart';
import 'package:keygrant/src/core/lease.dart';
import 'package:keygrant/src/core/merge.dart';
import 'package:keygrant/src/core/offline.dart';
import 'package:keygrant/src/core/stored_state.dart';
import 'package:keygrant/src/core/types.dart';

import 'harness.dart';

/// A valid licence lease's claims: the decisions read one or two of them; the
/// rest only make it a whole claim set (replay.ts `BASE_CLAIMS`).
LeaseClaims baseClaims({int? major, int? iat, int? exp, int? upgradeUntil}) => LeaseClaims(
      sub: 'SLUICE-AAAA-BBBB-CCCC-DDDD',
      product: 'sluice',
      aid: 'act_1',
      model: 'perpetual',
      lim: 3,
      major: major ?? 3,
      iat: iat ?? 1789913600,
      exp: exp ?? 1792505600,
      upgradeUntil: upgradeUntil,
    );

/// A vector's holder of a licence lease.
LeaseHolder holderOf(Object? json) {
  final h = json as Map<String, Object?>;
  return LeaseHolder(
    key: h['key'] as String,
    activationId: h['activationId'] as String,
    claims: texts(h['claims']),
    canTell: h['canTell'] as bool,
  );
}

/// A device as a vector gives it (replay.ts `deviceOf`): what its fingerprint
/// hashes, its own claim, whether it can tell, its claims.
({DeviceKind? kind, String? ownClaim, bool canTell, List<String> claims}) deviceOf(Object? json) {
  final d = (json as Map<String, Object?>?) ?? const {};
  final ownClaim = d['ownClaim'] as String?;
  return (
    kind: DeviceKind.fromWire(d['kind']),
    ownClaim: ownClaim,
    canTell: (d['canTell'] as bool?) ?? true,
    claims: d.containsKey('claims') ? texts(d['claims']) : [if (ownClaim != null) ownClaim],
  );
}

/// A stored state from JSON.
StoredState stateOf(Object? json) => StoredState.fromJson(json);

/// A response as a vector gives it: its status and JSON body, or null for none at all.
HttpResponse? responseOf(Object? json) {
  if (json == null) return null;
  final r = json as Map<String, Object?>;
  return HttpResponse((r['status'] as num).toInt(), r['json']);
}

/// A stamp, an ask, or a basis as a vector gives it.
Stamp? stampOf(Object? json) {
  final s = json as Map<String, Object?>?;
  return s == null ? null : Stamp(at: intOr(s['at'])!, seen: intOr(s['seen']));
}

Asked? askedOf(Object? json) {
  final s = json as Map<String, Object?>?;
  return s == null ? null : Asked(at: intOr(s['at'])!, seen: intOr(s['seen']), activationId: s['activationId'] as String?);
}

Basis basisOf(Object? json) {
  final b = json as Map<String, Object?>?;
  if (b == null) return const Basis();
  final about = b['about'] as Map<String, Object?>?;
  return Basis(
    answer: askedOf(b['answer']),
    activation: askedOf(b['activation']),
    about: about?['activationId'] as String?,
    aboutSet: about != null,
    trial: stampOf(b['trial']),
  );
}

/// A lease's offline check as a vector gives it (`renewals.check`).
LeaseCheck? checkOf(Object? json) {
  final c = json as Map<String, Object?>?;
  if (c == null) return null;
  if (c['ok'] == true) return LeaseCheck.ok(LeaseClaims.parse(c['claims'])!);
  return LeaseCheck.failed(CheckFailure.values.firstWhere((f) => f.wire == c['reason']));
}
