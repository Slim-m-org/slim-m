// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one classification every caught failure goes through.
library;

import 'dart:async';

import '../exceptions.dart';
import 'app_log.dart';

enum FailureKind {
  /// The request never reached the server; usually self-healing.
  offline,

  /// The session is no good; signing in again is the fix.
  authExpired,

  /// The server answered and said no (validation, permission, rate limit).
  refused,

  /// A bug or a local fault; nothing the user can wait out.
  unexpected,
}

/// A caught failure with what the UI needs to react to it.
final class ClassifiedFailure {
  const ClassifiedFailure(this.kind, this.error, this.stack);

  final FailureKind kind;
  final Object error;
  final StackTrace? stack;

  /// Worth retrying without the user doing anything.
  bool get retryable => kind == FailureKind.offline;

  LogLevel get level =>
      kind == FailureKind.unexpected ? LogLevel.error : LogLevel.warning;
}

FailureKind classifyFailureKind(Object error) => switch (error) {
      UnauthorizedException() => FailureKind.authExpired,
      TransportException() || TimeoutException() => FailureKind.offline,
      UnavailableException() => FailureKind.offline,
      ApiException() => FailureKind.refused,
      _ when _isSocketLevel(error) => FailureKind.offline,
      _ => FailureKind.unexpected,
    };

// dart:io is unavailable on web, so socket errors are recognised by name.
bool _isSocketLevel(Object error) {
  final name = error.runtimeType.toString();
  return name == 'SocketException' ||
      name == 'HandshakeException' ||
      name == 'WebSocketException' ||
      name == 'ClientException';
}

/// Classifies [error], logs it once under [tag], and returns the result.
///
/// [what] names the failed action ("send the message"); [context] holds
/// ids and counts, never content (it is redacted regardless).
ClassifiedFailure reportFailure(
  String tag,
  String what,
  Object error, [
  StackTrace? stack,
  Map<String, Object?>? context,
]) {
  final failure = ClassifiedFailure(classifyFailureKind(error), error, stack);
  final ctx = {'kind': failure.kind.name, ...?context};
  if (failure.level == LogLevel.error) {
    AppLog.error(tag, 'Could not $what',
        error: error, stack: stack, context: ctx);
  } else {
    AppLog.warning(tag, 'Could not $what',
        error: error, stack: stack, context: ctx);
  }
  return failure;
}

/// A `catchError` handler for a failure that is deliberately ignored.
void Function(Object, StackTrace) ignoreError(String tag, String reason) =>
    (error, stack) => AppLog.swallowed(tag, reason, error, stack);
