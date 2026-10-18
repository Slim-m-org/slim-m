// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the debug log screen is narrowed to: a level, a tag and a search term.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LogLevel;

import 'debug_log.dart';

@immutable
class DebugLogFilter {
  const DebugLogFilter({this.level, this.tag, this.query = ''});

  final LogLevel? level;
  final String? tag;
  final String query;

  bool get isActive => level != null || tag != null || query.trim().isNotEmpty;

  DebugLogFilter withLevel(LogLevel? next) =>
      DebugLogFilter(level: next, tag: tag, query: query);

  DebugLogFilter withTag(String? next) =>
      DebugLogFilter(level: level, tag: next, query: query);

  DebugLogFilter withQuery(String next) =>
      DebugLogFilter(level: level, tag: tag, query: next);

  bool matches(DiagnosticEvent e) {
    if (level != null && e.level != level) return false;
    if (tag != null && e.source != tag) return false;
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return e.toString().toLowerCase().contains(needle);
  }

  List<DiagnosticEvent> apply(List<DiagnosticEvent> events) => isActive
      ? [
          for (final e in events)
            if (matches(e)) e,
        ]
      : events;
}

final debugLogFilterProvider = StateProvider<DebugLogFilter>(
  (ref) => const DebugLogFilter(),
);

/// The entries the current filter lets through, newest first.
final shownDebugLogProvider = Provider<List<DiagnosticEvent>>(
  (ref) => ref.watch(debugLogFilterProvider).apply(ref.watch(debugLogProvider)),
);
