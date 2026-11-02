// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two numbers livekit_client logs about a new connection and nowhere else:
/// how long setup took, and the video start bitrate it hinted to the estimator.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'voice_log.dart';

/// The diagnostics line for one livekit log message, or null for any other.
String? setupDiagnostic(String loggerName, String message) {
  if (loggerName != 'livekit') return null;
  if (RegExp(r'^connection setup took \d+ ms$').hasMatch(message)) {
    return 'LiveKit: $message';
  }
  if (message.startsWith('Applying x-google-start-bitrate=')) {
    return 'LiveKit: $message';
  }
  return null;
}

/// Copies those two lines into the call's diagnostics while a room is held.
class LiveKitSetupLog {
  LiveKitSetupLog(this._log,
      {Stream<({String logger, String message})>? records})
      : _records = records ?? _livekitRecords();

  final VoiceLog _log;
  final Stream<({String logger, String message})> _records;
  StreamSubscription<({String logger, String message})>? _subscription;

  void start() {
    _subscription ??= _records.listen((record) {
      final line = setupDiagnostic(record.logger, record.message);
      if (line != null) _log(line);
    });
  }

  void stop() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  static Stream<({String logger, String message})> _livekitRecords() =>
      lk.logger.onRecord.map(
        (record) => (logger: record.loggerName, message: record.message),
      );
}
