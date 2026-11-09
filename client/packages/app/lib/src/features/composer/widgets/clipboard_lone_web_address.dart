// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

/// Whether clipboard [text] is one http(s) address and nothing else, which a
/// browser's "Copy image" writes beside the picture it copied.
bool isLoneWebAddress(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return false;
  final uri = Uri.tryParse(trimmed);
  return uri != null &&
      (uri.isScheme('http') || uri.isScheme('https')) &&
      uri.host.isNotEmpty;
}
