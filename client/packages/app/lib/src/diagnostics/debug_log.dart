// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-app record of what went wrong, so a failure can be reported without
/// a terminal attached. A packaged build has no stdout anybody reads.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DiagnosticSeverity { info, warning, error }

/// One thing worth telling the user about after the fact.
@immutable
class DiagnosticEvent {
  const DiagnosticEvent({
    required this.at,
    required this.level,
    required this.source,
    required this.message,
    this.detail,
  });

  final DateTime at;
  final DiagnosticSeverity level;

  /// A short origin tag: 'voice', 'flutter', 'platform'.
  final String source;
  final String message;

  /// A stack trace or platform error body, shown on expansion only.
  final String? detail;

  String get timestamp {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  @override
  String toString() {
    final head = '$timestamp  ${level.name.toUpperCase()}  [$source]  $message';
    return detail == null ? head : '$head\n$detail';
  }
}

/// A bounded, newest-first list of [DiagnosticEvent].
///
/// Bounded so a plugin that throws every frame drops the oldest entry rather
/// than growing without limit through a long session.
class DebugLog extends StateNotifier<List<DiagnosticEvent>> {
  DebugLog({this.capacity = 200}) : super(const []);

  final int capacity;

  void record(
    String source,
    String message, {
    DiagnosticSeverity level = DiagnosticSeverity.error,
    Object? detail,
  }) {
    final event = DiagnosticEvent(
      at: DateTime.now(),
      level: level,
      source: source,
      message: message,
      detail: detail?.toString(),
    );
    // Newest first, so the screen needs no reverse and the drop is a truncate.
    final next = [event, ...state];
    state = next.length > capacity ? next.sublist(0, capacity) : next;
  }

  void clear() => state = const [];

  /// The whole log as one block of text, oldest first, for the copy button.
  String asReport() => state.reversed.join('\n');
}

final debugLogProvider = StateNotifierProvider<DebugLog, List<DiagnosticEvent>>(
  (ref) => DebugLog(),
);

/// Routes framework and uncaught async errors into [debugLogProvider].
///
/// Both still forward to the previous handler, so a debug run keeps printing
/// as it did. Returning true from [PlatformDispatcher.onError] is what stops
/// an unhandled plugin teardown error from reaching the zone and killing the
/// app, which is the specific crash it was added for.
void installDiagnostics(ProviderContainer container) {
  final log = container.read(debugLogProvider.notifier);

  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    log.record(
      details.library ?? 'flutter',
      details.exceptionAsString(),
      detail: details.stack,
    );
    previousOnError?.call(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    log.record('platform', error.toString(), detail: stack);
    return true;
  };
}
