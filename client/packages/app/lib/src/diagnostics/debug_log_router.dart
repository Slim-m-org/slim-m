// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sends each record to the log of the account that wrote it.
library;

import 'package:slimm_api/api.dart';

import 'debug_log.dart';

/// Records stamped with an origin reach only that account's [DebugLog]; the
/// rest, which belong to no account, reach every one.
class DebugLogRouter implements DebugLogSink {
  final List<DebugLog> _logs = [];

  bool get isEmpty => _logs.isEmpty;

  void add(DebugLog log) => _logs.add(log);

  void remove(DebugLog log) => _logs.remove(log);

  @override
  void write(LogRecord record) {
    final scope = record.origin;
    for (final log in List.of(_logs)) {
      if (scope == null || log.origin?.call() == scope) log.write(record);
    }
  }

  @override
  void flush() {
    for (final log in List.of(_logs)) {
      log.flush();
    }
  }
}
