// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a server address the way a person types it.
library;

/// [text] as a server address, or null when it names no host.
///
/// A bare host or `host:port` gets `https://`, so the address a Space shares
/// works as it is written; an explicit scheme is kept for the scheme rule.
Uri? parseServerAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
  final typed = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final address = Uri.tryParse(typed);
  if (address == null || address.host.isEmpty) return null;
  return address;
}
