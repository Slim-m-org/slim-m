// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a failed request into a sentence, in the one place both
/// `runGuarded` and a bespoke catch clause can share it.
///
/// `TransportException.message` carries a method, a path and a Dart
/// exception (`client_transport.dart`'s own doc says so), which is a log
/// line, not copy: nothing here may put one of those in front of a user.
library;

import 'package:slimm_api/api.dart' as api;

import 'screens/admin/channel_permissions_escalation.dart';

/// Turns [e] into a plain sentence for [whatFailed] ("join the call"),
/// never the raw transport string a [api.TransportException] carries.
///
/// A [api.BadRequestException] or [api.ConflictException] appends the
/// server's own reason, which is worth reading; every other case names only
/// what is safe to say without it.
String describeApiFailure(String whatFailed, api.ApiException e) => switch (e) {
  api.BadRequestException() =>
    'Could not $whatFailed. ${sentenceCase(e.message)}',
  api.ConflictException() =>
    'Could not $whatFailed. ${sentenceCase(e.message)}',
  api.ForbiddenException(missingPermissions: final int bits?) when bits != 0 =>
    'Could not $whatFailed: you cannot grant ${joinLabels(permissionLabels(bits))}.',
  // The Dock's registry served content the server refuses; its reason names the field.
  api.ServerException(statusCode: 502) =>
    'Could not $whatFailed. ${sentenceCase(e.message)}',
  // 413 and 507 are told apart on purpose: one is this file, the other is the whole server.
  api.ServerException(statusCode: 413) =>
    'Could not $whatFailed: it is too big.',
  api.ServerException(statusCode: 507) =>
    'Could not $whatFailed: this server has no storage left. Tell an admin.',
  api.ForbiddenException() =>
    'Could not $whatFailed: you are not allowed to do that.',
  api.UnauthorizedException() =>
    'Could not $whatFailed: you are signed out. Sign in and try again.',
  // A slow-mode refusal names its own wait; show it verbatim rather than the generic rate-limit wording below.
  api.RateLimitedException(retryAfter: final Duration _) =>
    'Could not $whatFailed: ${sentenceCase(e.message)}',
  api.RateLimitedException() =>
    'Could not $whatFailed: too many requests just now. '
        'Wait a moment and try again.',
  api.TransportException() =>
    'Could not $whatFailed: the server could not be reached. '
        'Nothing was changed.',
  api.ApiException() => 'Could not $whatFailed.',
};

/// Normalizes a raw string this client did not write into the sentence
/// case and closing punctuation every hand-written message on the same
/// screen already carries: capitalizes the first letter and adds a
/// trailing period if it lacks terminal punctuation.
///
/// This never rewrites what the server said, only how the sentence is
/// cased and closed, so a validator's wording stays the validator's own -
/// the one place this display seam is allowed to touch a server string at
/// all.
String sentenceCase(String s) {
  if (s.isEmpty) return s;
  final capitalized = s[0].toUpperCase() + s.substring(1);
  return RegExp(r'[.!?]$').hasMatch(capitalized)
      ? capitalized
      : '$capitalized.';
}
