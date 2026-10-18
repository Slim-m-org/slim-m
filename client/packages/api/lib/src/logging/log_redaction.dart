// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scrubbing applied to every log record before any sink sees it.
library;

const redactedMark = '[redacted]';

/// Context keys whose value is never logged: credentials and user content.
const _sensitiveKeys = {
  'token',
  'accesstoken',
  'refreshtoken',
  'password',
  'passphrase',
  'secret',
  'authorization',
  'cookie',
  'apikey',
  'code',
  'content',
  'body',
  'text',
  'markdown',
  'message',
  'caption',
};

final _keyedSecret = RegExp(
  r'''(token|password|passphrase|secret|authorization|cookie|api[_-]?key|reset[_-]?code)(["']?\s*[:=]\s*)(?:Bearer\s+)?["']?[^\s,"'&}\]]+''',
  caseSensitive: false,
);
final _bearer = RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final _jwt = RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*');
final _opaque =
    RegExp(r'(?<![A-Za-z0-9_-])[A-Za-z0-9_+=-]{40,}(?![A-Za-z0-9_-])');

/// [text] with credentials and long opaque tokens replaced by [redactedMark].
String redactText(String text) {
  return text
      .replaceAllMapped(_bearer, (_) => 'Bearer $redactedMark')
      .replaceAllMapped(_jwt, (_) => redactedMark)
      .replaceAllMapped(_keyedSecret, (m) => '${m[1]}${m[2]}$redactedMark')
      .replaceAll(_opaque, redactedMark);
}

/// [context] with sensitive keys masked and every other value scrubbed.
Map<String, String> redactContext(Map<String, Object?> context) {
  return {
    for (final entry in context.entries)
      entry.key:
          _isSensitive(entry.key) ? redactedMark : redactText('${entry.value}'),
  };
}

bool _isSensitive(String key) {
  final flat = key.toLowerCase().replaceAll(RegExp('[_-]'), '');
  return _sensitiveKeys.contains(flat) ||
      const ['token', 'password', 'secret', 'resetcode'].any(flat.contains);
}
