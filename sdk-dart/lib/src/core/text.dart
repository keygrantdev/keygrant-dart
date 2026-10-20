/// Text as the reference (JavaScript) handles it: lengths in UTF-16 units
/// (which Dart's `String.length` already counts) and JavaScript's `trim`.
library;

/// Whether a UTF-16 unit is one JavaScript's `trim` removes: its white space
/// (tab, vertical tab, form feed, space, no-break space, the byte-order mark and
/// every other space separator) and its line terminators. Dart's own `trim`
/// also removes U+0085, which JavaScript keeps.
bool _jsSpace(int unit) {
  switch (unit) {
    case 0x09:
    case 0x0A:
    case 0x0B:
    case 0x0C:
    case 0x0D:
    case 0x20:
    case 0xA0:
    case 0x1680:
    case 0x2028:
    case 0x2029:
    case 0x202F:
    case 0x205F:
    case 0x3000:
    case 0xFEFF:
      return true;
  }
  return unit >= 0x2000 && unit <= 0x200A;
}

/// `text` without the white space and line terminators JavaScript's `trim`
/// removes from each end.
String jsTrim(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _jsSpace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _jsSpace(text.codeUnitAt(end - 1))) {
    end--;
  }
  return start == 0 && end == text.length ? text : text.substring(start, end);
}

/// `value` cut to `max` UTF-16 units without splitting a character: a high
/// surrogate left alone at the end is dropped. A device name is a label; it can
/// lose its last emoji rather than its last half-emoji.
String? trimToLength(String? value, int max) {
  if (value == null || value.length <= max) return value;
  final cut = value.substring(0, max);
  final last = cut.codeUnitAt(max - 1);
  return last >= 0xD800 && last <= 0xDBFF ? cut.substring(0, max - 1) : cut;
}
