// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the debug log across a restart, so a crash can still be reported.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:slimm_api/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log.dart';

abstract interface class DebugLogPersistence {
  Future<List<DiagnosticEvent>> load();
  Future<void> save(List<DiagnosticEvent> events);
}

/// A ring held in one preferences string per account, so it works on every platform.
class PrefsDebugLogPersistence implements DebugLogPersistence {
  const PrefsDebugLogPersistence({required this.origin});

  /// The account whose log this is; null until it has one, and nothing is read or kept meanwhile.
  final String? Function() origin;

  static const _legacyKey = 'debug_log.v1';
  static const _keyPrefix = 'debug_log.v2.';
  static const maxDetail = 1000;
  static const maxEvents = 500;

  String? get _key {
    final scope = origin();
    return scope == null ? null : '$_keyPrefix${Uri.encodeComponent(scope)}';
  }

  @override
  Future<List<DiagnosticEvent>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The shared v1 ring cannot be told apart by account, so it is dropped rather than shown to any of them.
      if (prefs.containsKey(_legacyKey)) await prefs.remove(_legacyKey);
      final key = _key;
      final raw = key == null ? null : prefs.getString(key);
      if (raw == null) return const [];
      return decodeEvents(raw);
    } on Object catch (e, s) {
      AppLog.debug(
        LogTag.data,
        'Could not read the saved debug log; starting empty',
        error: e,
        stack: s,
      );
      return const [];
    }
  }

  @override
  Future<void> save(List<DiagnosticEvent> events) async {
    final key = _key;
    if (key == null) return;
    try {
      final capped = events.length > maxEvents
          ? events.sublist(0, maxEvents)
          : events;
      final encoded = kIsWeb || capped.length < 50
          ? encodeEvents(capped)
          : await compute(encodeEvents, capped);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, encoded);
    } on Object catch (e, s) {
      AppLog.debug(
        LogTag.data,
        'Could not save the debug log',
        error: e,
        stack: s,
      );
    }
  }
}

String encodeEvents(List<DiagnosticEvent> events) => jsonEncode([
  for (final e in events)
    {
      'at': e.at.toIso8601String(),
      'level': e.level.name,
      'tag': e.source,
      'message': e.message,
      'detail':
          e.detail != null &&
              e.detail!.length > PrefsDebugLogPersistence.maxDetail
          ? e.detail!.substring(0, PrefsDebugLogPersistence.maxDetail)
          : e.detail,
      'context': e.context,
      'count': e.count,
    },
]);

List<DiagnosticEvent> decodeEvents(String raw) {
  final list = jsonDecode(raw) as List<dynamic>;
  return [
    for (final item in list.cast<Map<String, dynamic>>())
      DiagnosticEvent(
        at: DateTime.parse(item['at'] as String),
        level: LogLevel.values.byName(item['level'] as String),
        source: item['tag'] as String,
        message: redactText(item['message'] as String),
        detail: item['detail'] == null
            ? null
            : redactText(item['detail'] as String),
        context: redactContext(
          (item['context'] as Map).cast<String, Object?>(),
        ),
        count: item['count'] as int,
      ),
  ];
}
