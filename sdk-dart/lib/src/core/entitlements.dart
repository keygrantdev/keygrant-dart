/// Entitlements (the SDK contract, 2.1 and 5.9): what a licence grants beyond
/// the base product, read leniently from a lease's `ent`, and whether they
/// grant a code.
library;

import 'json.dart';

/// One entitlement's value: a flag, a number (a double, as JSON reads one) or
/// a text. Compared by content: `NumberEntitlement(5)` equals
/// `NumberEntitlement(5.0)`.
sealed class Entitlement {
  const Entitlement();

  /// The value as JSON writes it: a `bool`, a `double` or a `String`.
  Object get value;

  /// The entitlement JSON holds, or null when it is not a flag, number or text.
  static Entitlement? fromJson(Object? json) => switch (json) {
        bool flag => FlagEntitlement(flag),
        num number => NumberEntitlement(number.toDouble()),
        String text => TextEntitlement(text),
        _ => null,
      };

  @override
  bool operator ==(Object other) => other is Entitlement && other.runtimeType == runtimeType && other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => '$value';
}

/// A flag: granted when true.
final class FlagEntitlement extends Entitlement {
  const FlagEntitlement(this.value);
  @override
  final bool value;
}

/// A number: granted when not 0 (a negative counts: -1 for unlimited).
final class NumberEntitlement extends Entitlement {
  const NumberEntitlement(this.value);
  @override
  final double value;
}

/// A text: granted when not empty.
final class TextEntitlement extends Entitlement {
  const TextEntitlement(this.value);
  @override
  final String value;
}

/// `ent` as a verifier reads it: an object's flag, number and text members,
/// kept as they are; every other member (an object, a list, null) dropped; and
/// nothing at all from anything but an object. Never a refusal. A member named
/// `__proto__` is an entitlement like any other.
Map<String, Entitlement> entitlementsOf(Object? raw) {
  final object = raw is List ? null : asObject(raw);
  if (object == null) return const {};
  return {
    for (final entry in object.entries)
      if (Entitlement.fromJson(entry.value) case final value?) entry.key: value,
  };
}

/// Whether entitlements grant `code`: a flag that is on, a number that is not
/// zero, or a text that is not empty. Absent, off, zero or empty is not
/// granted. The code is matched exactly, case included.
bool grants(Map<String, Entitlement>? entitlements, String code) => switch (entitlements?[code]) {
      FlagEntitlement(:final value) => value,
      NumberEntitlement(:final value) => value != 0,
      TextEntitlement(:final value) => value.isNotEmpty,
      null => false,
    };

/// The entitlements as JSON writes them, for a status's JSON form.
Map<String, Object> entitlementsJson(Map<String, Entitlement> entitlements) =>
    entitlements.map((name, value) => MapEntry(name, value.value));

/// What `KeyGrantLicense.require` throws when the licence does not grant an
/// entitlement: it names it as [entitlement].
final class MissingEntitlement implements Exception {
  const MissingEntitlement(this.entitlement);

  /// The entitlement's code, as the app asked for it.
  final String entitlement;

  @override
  String toString() => 'MissingEntitlement: the licence does not grant "$entitlement"';
}
