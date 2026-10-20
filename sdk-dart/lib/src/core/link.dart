/// A payment link with a reference of this install's on it (the SDK contract,
/// 5.4; link.ts): `upgradeUrl`'s, which names the activation an upgrade sale
/// finds the key by.
library;

const String _reference = 'client_reference_id';

/// `link` with `reference` as its one `client_reference_id`, or null when the
/// link is not an absolute URL. The link is read as an absolute URL (which
/// writes it in its normal form: a lower-case scheme and host), and its query
/// is then edited as text: every parameter named exactly `client_reference_id`
/// (its text before the first `=`, or all of it) and every empty one is left
/// out, the others are kept as written and in their order, and
/// `client_reference_id=<reference>` (percent-encoded as a URI component) is
/// added last. The fragment is kept.
String? referencedLink(String link, String reference) {
  final Uri uri;
  try {
    uri = Uri.parse(link);
  } on FormatException {
    return null;
  }
  if (!uri.hasScheme || !uri.hasAuthority && uri.path.isEmpty) return null;
  final kept = uri.query.split('&').where((part) => part.isNotEmpty && part.split('=').first != _reference);
  final query = [...kept, '$_reference=${Uri.encodeComponent(reference)}'].join('&');
  // As a WHATWG URL writes a special scheme's empty path: "/".
  final special = uri.scheme == 'http' || uri.scheme == 'https';
  final normal = special && uri.path.isEmpty ? uri.replace(path: '/') : uri;
  final base = normal.removeFragment().replace(query: '').toString();
  final withoutQuery = base.endsWith('?') ? base.substring(0, base.length - 1) : base;
  return '$withoutQuery?$query${uri.hasFragment ? '#${uri.fragment}' : ''}';
}
