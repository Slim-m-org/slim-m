// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-app record of what went wrong, so a failure can be reported without
/// a terminal attached. A packaged build has no stdout anybody reads.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'debug_log_persistence.dart';

typedef DiagnosticSeverity = LogLevel;

/// One thing worth telling the user about after the fact.
@immutable
class DiagnosticEvent {
  const DiagnosticEvent({
    required this.at,
    required this.level,
    required this.source,
    required this.message,
    this.detail,
    this.context = const {},
    this.count = 1,
  });

  final DateTime at;
  final LogLevel level;

  /// A short origin tag, one of [LogTag] or a framework library name.
  final String source;
  final String message;

  /// The error and stack trace, shown on expansion only.
  final String? detail;
  final Map<String, String> context;

  /// How many identical consecutive records this stands for.
  final int count;

  String get timestamp {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  /// Context and error text as shown on expansion; null when there is none.
  String? get expandedText {
    final ctx = context.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    final parts = [if (ctx.isNotEmpty) ctx, ?detail];
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  DiagnosticEvent repeated(DateTime now) => DiagnosticEvent(
    at: now,
    level: level,
    source: source,
    message: message,
    detail: detail,
    context: context,
    count: count + 1,
  );

  bool sameAs(DiagnosticEvent other) =>
      level == other.level &&
      source == other.source &&
      message == other.message &&
      detail == other.detail &&
      mapEquals(context, other.context);

  @override
  String toString() {
    final times = count > 1 ? '  x$count' : '';
    final head =
        '$timestamp  ${level.name.toUpperCase()}  [$source]  $message$times';
    final ctx = context.isEmpty
        ? ''
        : '\n  ${context.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    final tail = detail == null ? '' : '\n$detail';
    return '$head$ctx$tail';
  }
}

/// A bounded, newest-first list of [DiagnosticEvent] and the app's [LogSink].
///
/// Bounded so a plugin that throws every frame drops the oldest entry rather
/// than growing without limit through a long session.
class DebugLog extends StateNotifier<List<DiagnosticEvent>> implements LogSink {
  DebugLog({
    this.capacity = 200,
    this.persistence,
    this.echo = false,
    this.saveDelay = const Duration(seconds: 2),
  }) : super(const []) {
    unawaited(_restore());
  }

  final int capacity;
  final DebugLogPersistence? persistence;

  /// Mirrors every record to the console, for a debug run with a terminal.
  final bool echo;
  final Duration saveDelay;
  Timer? _saveTimer;
  bool _touched = false;

  Future<void> _restore() async {
    final saved = await persistence?.load() ?? const [];
    if (!mounted || saved.isEmpty) return;
    final merged = [...state, ...saved];
    state = merged.length > capacity ? merged.sublist(0, capacity) : merged;
  }

  @override
  void write(LogRecord record) {
    _touched = true;
    final event = DiagnosticEvent(
      at: record.at,
      level: record.level,
      source: record.tag,
      message: record.message,
      detail: _detail(record),
      context: record.context,
    );
    if (echo) debugPrint(redactText(event.toString()));
    final last = state.isEmpty ? null : state.first;
    // A retry loop would otherwise push everything useful out of the ring.
    final next = last != null && last.sameAs(event)
        ? [last.repeated(event.at), ...state.skip(1)]
        : [event, ...state];
    state = _bounded(next);
    _scheduleSave();
  }

  /// Drops the oldest debug record first, so a chatty source cannot push an error out.
  List<DiagnosticEvent> _bounded(List<DiagnosticEvent> events) {
    if (events.length <= capacity) return events;
    final trimmed = List.of(events);
    final victim = trimmed.lastIndexWhere((e) => e.level == LogLevel.debug);
    trimmed.removeAt(victim == -1 ? trimmed.length - 1 : victim);
    return trimmed;
  }

  String? _detail(LogRecord r) {
    final parts = [?r.error, ?r.stack];
    return parts.isEmpty ? null : parts.join('\n');
  }

  /// Compatibility entry for callers that already hold a source and a message.
  void record(
    String source,
    String message, {
    LogLevel level = LogLevel.error,
    Object? detail,
  }) {
    write(
      LogRecord(
        at: DateTime.now(),
        level: level,
        tag: source,
        message: redactText(message),
        error: detail == null ? null : redactText('$detail'),
      ),
    );
  }

  void clear() {
    state = const [];
    _touched = true;
    _scheduleSave();
  }

  void _scheduleSave() {
    if (persistence == null) return;
    _saveTimer ??= Timer(saveDelay, () {
      _saveTimer = null;
      if (_touched) unawaited(persistence!.save(state));
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  /// [events] (default: everything) as one block of redacted text, oldest first.
  String asReport([Iterable<DiagnosticEvent>? events]) => (events ?? state)
      .toList()
      .reversed
      .map((e) => redactText(e.toString()))
      .join('\n');
}

final debugLogProvider = StateNotifierProvider<DebugLog, List<DiagnosticEvent>>(
  (ref) => DebugLog(),
);

/// Routes framework and uncaught async errors, and every [AppLog] record,
/// into [debugLogProvider].
///
/// Both handlers still forward to the previous one, so a debug run keeps
/// printing as it did. Returning true from [PlatformDispatcher.onError] is
/// what stops an unhandled plugin teardown error from reaching the zone and
/// killing the app, which is the specific crash it was added for.
void installDiagnostics(ProviderContainer container) {
  final log = container.read(debugLogProvider.notifier);
  AppLog.install(log);

  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    AppLog.error(
      details.library ?? 'flutter',
      details.exceptionAsString(),
      stack: details.stack,
    );
    previousOnError?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.error(LogTag.platform, error.toString(), stack: stack);
    return true;
  };
}
