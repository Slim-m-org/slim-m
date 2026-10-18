// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one logging entry point for the whole client.
///
/// It lives in the api package because that is the lowest layer every other
/// package already depends on; the app installs the sink that keeps records.
library;

import 'log_redaction.dart';

enum LogLevel { debug, info, warning, error }

/// Short origin tags, so the log screen can filter on a closed set.
abstract final class LogTag {
  static const sync = 'sync';
  static const push = 'push';
  static const voice = 'voice';
  static const auth = 'auth';
  static const media = 'media';
  static const data = 'data';
  static const platform = 'platform';
  static const ui = 'ui';
  static const net = 'net';
}

/// One already-redacted entry.
final class LogRecord {
  const LogRecord({
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
    this.error,
    this.stack,
    this.context = const {},
  });

  final DateTime at;
  final LogLevel level;
  final String tag;
  final String message;
  final String? error;
  final String? stack;
  final Map<String, String> context;
}

/// Where records go; the app installs one at startup.
abstract interface class LogSink {
  void write(LogRecord record);
}

/// Static facade so a static helper or a package with no provider scope can log.
abstract final class AppLog {
  static const _pendingCapacity = 100;
  static LogSink? _sink;
  static final List<LogRecord> _pending = [];

  /// Installs [sink] and hands it whatever was logged before it existed.
  static void install(LogSink? sink) {
    _sink = sink;
    if (sink == null) return;
    final early = List.of(_pending);
    _pending.clear();
    early.forEach(sink.write);
  }

  static void debug(String tag, String message,
          {Object? error, StackTrace? stack, Map<String, Object?>? context}) =>
      _log(LogLevel.debug, tag, message, error, stack, context);

  static void info(String tag, String message,
          {Object? error, StackTrace? stack, Map<String, Object?>? context}) =>
      _log(LogLevel.info, tag, message, error, stack, context);

  static void warning(String tag, String message,
          {Object? error, StackTrace? stack, Map<String, Object?>? context}) =>
      _log(LogLevel.warning, tag, message, error, stack, context);

  static void error(String tag, String message,
          {Object? error, StackTrace? stack, Map<String, Object?>? context}) =>
      _log(LogLevel.error, tag, message, error, stack, context);

  /// A failure that is deliberately ignored; [reason] says why that is safe.
  static void swallowed(String tag, String reason, Object error,
          [StackTrace? stack]) =>
      _log(LogLevel.debug, tag, reason, error, stack, null);

  static void _log(
    LogLevel level,
    String tag,
    String message,
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? context,
  ) {
    final record = LogRecord(
      at: DateTime.now(),
      level: level,
      tag: tag,
      message: redactText(message),
      error: error == null ? null : redactText('$error'),
      stack: stack == null ? null : redactText('$stack'),
      context: context == null ? const {} : redactContext(context),
    );
    final sink = _sink;
    if (sink != null) {
      sink.write(record);
      return;
    }
    if (_pending.length >= _pendingCapacity) _pending.removeAt(0);
    _pending.add(record);
  }
}
