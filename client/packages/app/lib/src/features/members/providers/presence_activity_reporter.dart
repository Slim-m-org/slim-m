// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the server when the person is really at this device, so a client
/// left running on a sleeping or untouched machine shows away instead of
/// online. Owner report: "a user is still marked as online even though their
/// computer has been asleep and not touched in 8 hours".
///
/// Here means input in the app, input anywhere on the machine where the host
/// can tell ([SystemIdle]), or being in a call. Every account container
/// reports: being at the machine counts for each server, not only the one on
/// screen.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../../providers/sync_controller.dart';
import '../../../providers/viewing_reporter.dart';
import '../../voice/providers/voice_flags.dart';

/// How often an `active` frame goes out while the person is here; well inside
/// the server's ten-minute idle window.
const presenceActiveInterval = Duration(minutes: 1);

/// How recent input still counts as here when a connection opens, just inside
/// the server's ten-minute idle window, so a reconnect does not flip a reader to away.
const presenceHelloWindow = Duration(minutes: 9);

class PresenceActivityReporter implements InputListener {
  PresenceActivityReporter({
    required bool Function() send,
    required bool Function() inCall,
    SystemIdle? systemIdle,
    Duration interval = presenceActiveInterval,
  }) : _send = send,
       _inCall = inCall,
       _systemIdle = systemIdle,
       _interval = interval;

  /// Whether a live connection took the frame.
  final bool Function() _send;
  final bool Function() _inCall;
  final SystemIdle? _systemIdle;
  final Duration _interval;
  Timer? _timer;
  DateTime? _lastInput;
  DateTime? _lastSent;

  void start() {
    _timer ??= Timer.periodic(_interval, (_) {
      if (here()) _report(minGap: _interval ~/ 2);
    });
  }

  /// Whether the person used this device within the last interval.
  bool here() => _hereWithin(_interval);

  /// What a new connection claims: here within the server's idle window.
  bool hereAtHello() => _hereWithin(presenceHelloWindow);

  bool _hereWithin(Duration window) {
    final now = clock.now();
    final input = _lastInput;
    if (input != null && now.difference(input) < window) return true;
    final idle = _systemIdle?.idleTime();
    if (idle != null && idle < window) return true;
    return _inCall();
  }

  /// Reports at once on the first input after a quiet interval, so coming
  /// back to the machine clears away without waiting for the timer.
  @override
  void noteInput() {
    _lastInput = clock.now();
    _report(minGap: _interval);
  }

  void _report({required Duration minGap}) {
    final now = clock.now();
    final last = _lastSent;
    if (last != null && now.difference(last) < minGap) return;
    if (_send()) _lastSent = now;
  }

  void dispose() => _timer?.cancel();
}

final presenceActivityReporterProvider = Provider<PresenceActivityReporter>((
  ref,
) {
  final sync = ref.read(syncControllerProvider.notifier);
  final reporter = PresenceActivityReporter(
    send: sync.notifyActive,
    inCall: () =>
        ref.read(voiceFlagsProvider).state == VoiceSessionState.connected,
    systemIdle: createSystemIdle(),
  );
  sync.activeAtHello = reporter.hereAtHello;
  ViewingInput.instance.add(reporter);
  reporter.start();
  ref.onDispose(() {
    if (sync.activeAtHello == reporter.hereAtHello) sync.activeAtHello = null;
    ViewingInput.instance.remove(reporter);
    reporter.dispose();
  });
  return reporter;
});
