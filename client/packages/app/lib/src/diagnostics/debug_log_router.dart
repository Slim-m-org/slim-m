// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sends each record to the log of the account that wrote it.
library;

import 'package:slimm_api/api.dart';

import 'debug_log.dart';

/// Records stamped with an origin reach only that account's [DebugLog]; the
/// rest reach the on-screen account's. Until a first log exists, records wait
/// in a bounded buffer and go to the first one added.
class DebugLogRouter implements DebugLogSink {
  DebugLogRouter({String? Function()? onScreenOrigin})
    : _onScreenOrigin = onScreenOrigin;

  static const _bufferCapacity = 100;

  final String? Function()? _onScreenOrigin;
  final List<DebugLog> _logs = [];
  final List<LogRecord> _early = [];

  bool get isEmpty => _logs.isEmpty;

  void add(DebugLog log) {
    _logs.add(log);
    final early = List.of(_early);
    _early.clear();
    early.forEach(log.write);
  }

  void remove(DebugLog log) => _logs.remove(log);

  @override
  void write(LogRecord record) {
    if (_logs.isEmpty) {
      if (_early.length >= _bufferCapacity) _early.removeAt(0);
      _early.add(record);
      return;
    }
    final scope = record.origin ?? _onScreenOrigin?.call();
    for (final log in List.of(_logs)) {
      if (log.origin?.call() == scope) log.write(record);
    }
  }

  @override
  void flush() {
    for (final log in List.of(_logs)) {
      log.flush();
    }
  }
}
