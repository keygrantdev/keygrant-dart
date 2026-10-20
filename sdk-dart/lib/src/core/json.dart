/// Reading JSON values as the reference (JavaScript) reads them: every number
/// a double, a whole number one with no fractional part, and an object a map
/// of its members. `dart:convert` reads an integer literal as an `int`, so the
/// checks here take an `int` or a `double` alike.
library;

/// The largest whole number a double holds exactly: 2^53 - 1 (JavaScript's
/// `Number.MAX_SAFE_INTEGER`).
const int maxSafeInteger = 9007199254740991;

/// The largest magnitude a whole double is taken as an `int` at.
const double _intRange = 9.2e18;

/// A JSON object as a map of its members, or null for anything else (a list
/// included).
Map<String, Object?>? asObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.map((k, v) => MapEntry('$k', v));
  return null;
}

/// A JSON number as an `int` when it is a whole number (JavaScript's
/// `Number.isInteger`), or null for anything else: a fraction, an infinity, a
/// text. A whole double too large for an `int` is none: no field read so holds
/// one the server writes.
int? wholeOf(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble() && value.abs() < _intRange) {
    return value.toInt();
  }
  return null;
}

/// A JSON number as an `int` when it is a whole number a double holds exactly
/// (JavaScript's `Number.isSafeInteger`), or null.
int? safeWholeOf(Object? value) {
  final whole = wholeOf(value);
  return whole != null && whole.abs() <= maxSafeInteger ? whole : null;
}

/// A whole number from 0 to 2^53 - 1, or null.
int? figureOf(Object? value) {
  final whole = safeWholeOf(value);
  return whole != null && whole >= 0 ? whole : null;
}

/// A JSON number as a double, as JavaScript reads one; null for anything else.
double? doubleOf(Object? value) => value is num ? value.toDouble() : null;

/// Whether two JSON values are the same: numbers compared as numbers (5 and
/// 5.0 alike), lists in order, objects by their members.
bool jsonEquals(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// `map` without its null members: what JavaScript's `JSON.stringify` writes
/// of an object whose absent members are undefined.
Map<String, Object?> withoutNulls(Map<String, Object?> map) => {
      for (final entry in map.entries)
        if (entry.value != null) entry.key: entry.value,
    };
