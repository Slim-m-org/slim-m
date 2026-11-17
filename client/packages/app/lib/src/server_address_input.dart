// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a server address the way a person types it.
library;

/// `http:/host`, `http//host` and friends: a scheme typed without `://`,
/// which prefixing `https://` would turn into a host named `http`.
final _brokenScheme = RegExp(
  r'^([a-z][a-z0-9+.-]*:/|https?/)',
  caseSensitive: false,
);

bool _hasBrokenScheme(String text) =>
    !text.contains('://') && _brokenScheme.hasMatch(text);

/// [text] as a server address, or null when it names no host.
///
/// A bare host or `host:port` gets `https://`, so the address a Space shares
/// works as it is written; an explicit scheme is kept for the scheme rule.
Uri? parseServerAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
  if (_hasBrokenScheme(trimmed)) return null;
  final typed = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final address = Uri.tryParse(typed);
  if (address == null || address.host.isEmpty) return null;
  return address;
}

/// Why [parseServerAddress] refused [text], in words for the field.
String serverAddressError(String text) => _hasBrokenScheme(text.trim())
    ? 'Check the start of the address. It should begin with https://'
    : 'That does not look like a server address.';
