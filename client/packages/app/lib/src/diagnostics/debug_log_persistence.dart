// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the debug log across a restart, so a crash can still be reported.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log.dart';

abstract interface class DebugLogPersistence {
  Future<List<DiagnosticEvent>> load();
  Future<void> save(List<DiagnosticEvent> events);
}

/// A ring held in one preferences string, so it works on every platform.
class PrefsDebugLogPersistence implements DebugLogPersistence {
  const PrefsDebugLogPersistence();

  static const _key = 'debug_log.v1';
  static const _maxDetail = 2000;

  @override
  Future<List<DiagnosticEvent>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, encodeEvents(events));
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
              e.detail!.length > PrefsDebugLogPersistence._maxDetail
          ? e.detail!.substring(0, PrefsDebugLogPersistence._maxDetail)
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
