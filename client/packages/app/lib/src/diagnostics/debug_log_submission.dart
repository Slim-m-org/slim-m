// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The debug log as it leaves the device for the admins: scrubbed once more
/// than the copy button does, and cut to what the server accepts.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart' show redactText, redactedMark;

/// The most log text the server accepts, in UTF-8 bytes.
const int debugLogSubmissionMaxBytes = 1024 * 1024;

/// JSON string values under keys that carry what a person wrote.
final _contentValue = RegExp(
  r'''("(?:content|body|text|markdown|caption|message|note)"\s*:\s*)"(?:[^"\\]|\\.)*"''',
  caseSensitive: false,
);

/// Short-lived or one-time credentials the shared redaction does not name.
final _credentialValue = RegExp(
  r'''(ticket|session|handoff|invite|otp|totp|recovery|refresh|access|passcode|pin)(["']?\s*[:=]\s*)["']?[^\s,"'&}\]]+''',
  caseSensitive: false,
);

final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

/// [report] with credentials, written content and email addresses replaced by
/// [redactedMark], on top of what every log record already had removed.
String scrubDebugLog(String report) {
  return redactText(report)
      .replaceAllMapped(_contentValue, (m) => '${m[1]}"$redactedMark"')
      .replaceAllMapped(_credentialValue, (m) => '${m[1]}${m[2]}$redactedMark')
      .replaceAll(_email, redactedMark);
}

/// [report] scrubbed and, when over [maxBytes], reduced to its newest lines.
///
/// A report reads oldest first, so the lines kept are the tail.
String debugLogSubmission(
  String report, {
  int maxBytes = debugLogSubmissionMaxBytes,
}) {
  final scrubbed = scrubDebugLog(report);
  if (utf8.encode(scrubbed).length <= maxBytes) return scrubbed;
  final lines = scrubbed.split('\n');
  var kept = 0;
  var start = lines.length;
  while (start > 0) {
    final next = utf8.encode(lines[start - 1]).length + 1;
    if (kept + next > maxBytes) break;
    kept += next;
    start--;
  }
  return lines.sublist(start).join('\n');
}
