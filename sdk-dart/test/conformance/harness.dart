// The conformance harness: `../conformance/vectors.json` (generated from the
// Electron SDK, the reference) holds what every KeyGrant SDK must answer for
// the same inputs. Each group is answered from the vector's own JSON, through
// the functions the SDK itself decides with, and every answer must match.
//
// The file's conventions: times are milliseconds (lease claims seconds); a
// state has absent fields unset; in a patch, null clears a field and an absent
// field is left alone; an answer of nothing is null; numbers are compared as
// numbers (5 and 5.0 alike).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keygrant/src/core/json.dart';
import 'package:keygrant/src/core/keys.dart';

/// The vectors' path: the repository's, or KEYGRANT_VECTORS (a set just
/// regenerated from the reference, say).
String get vectorsPath => Platform.environment['KEYGRANT_VECTORS'] ?? '../conformance/vectors.json';

Map<String, Object?>? _vectors;

/// The vectors file, read once.
Map<String, Object?> vectors() =>
    _vectors ??= jsonDecode(File(vectorsPath).readAsStringSync()) as Map<String, Object?>;

/// The file's `publicJwk` as a key set of one.
List<VerifyingKey> fileKeys() => importVerifyingKeys([vectors()['publicJwk']]);

/// Every group this harness answers, filled as each group is registered.
final Set<String> answeredGroups = {};

/// How many vectors each group answered.
final Map<String, int> answeredVectors = {};

/// The vectors of `name`, each a JSON object.
List<Map<String, Object?>> groupOf(String name) {
  final items = vectors()[name];
  if (items is! List || items.isEmpty) throw StateError('no `$name` group');
  return [for (final item in items) item as Map<String, Object?>];
}

/// A vector's label, for messages.
String label(Map<String, Object?> v) => (v['name'] as String?) ?? jsonEncode(v).substring(0, 80.clamp(0, jsonEncode(v).length));

/// The member names a vector holds an answer in (replay.ts `outputs`); `status` is an
/// answer only in `licenseFiles` (an input in `noAnswer`).
const _outputs = {'expect', 'verify', 'claim', 'fingerprint', 'kids', 'trial'};

/// Register the test of group `name`: every vector answered by `answer`, each
/// of whose members must equal the vector's member of that name. A vector
/// marked `jsOnly` is skipped, as every typed port skips it.
void conformanceGroup(String name, FutureOr<Map<String, Object?>> Function(Map<String, Object?> v) answer,
    {Set<String> outputs = _outputs}) {
  answeredGroups.add(name);
  test('conformance: $name', () async {
    final failures = <String>[];
    var answered = 0;
    for (final v in groupOf(name)) {
      if (v['jsOnly'] == true) continue;
      final Map<String, Object?> got;
      try {
        got = await answer(v);
      } catch (e, s) {
        failures.add('${label(v)}: threw $e\n$s');
        continue;
      }
      for (final MapEntry(:key, :value) in got.entries) {
        if (!v.containsKey(key)) {
          failures.add('${label(v)}: the vector has no `$key`');
        } else if (!jsonEquals(value, v[key])) {
          failures.add('${label(v)}: $key\n  got:    ${jsonEncode(value)}\n  wanted: ${jsonEncode(v[key])}');
        }
      }
      for (final output in outputs) {
        if (v.containsKey(output) && !got.containsKey(output)) failures.add('${label(v)}: `$output` not answered');
      }
      answered++;
    }
    answeredVectors[name] = answered;
    expect(failures, isEmpty, reason: failures.take(8).join('\n'));
  });
}

/// A JSON value as text or null.
String? textOr(Object? value) => value as String?;

/// A JSON number as an int, or null.
int? intOr(Object? value) => value == null ? null : (value as num).toInt();

/// A list of texts.
List<String> texts(Object? value) => [for (final t in (value as List?) ?? const []) t as String];
