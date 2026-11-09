// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the server when the person is really at this device, so an untouched or sleeping machine shows away instead of online.
/// Here means app input, host-wide input where known ([SystemIdle]), or being in a call that is not left running unattended; every account container reports.
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

/// How long the machine may sit untouched before a call alone stops counting as here; speaking in it still does.
const presenceCallIdleLimit = Duration(minutes: 10);

class PresenceActivityReporter implements InputListener {
  PresenceActivityReporter({
    required bool Function() send,
    required bool Function() inCall,
    bool Function()? speaking,
    SystemIdle? systemIdle,
    Duration interval = presenceActiveInterval,
  }) : _send = send,
       _inCall = inCall,
       _speaking = speaking,
       _systemIdle = systemIdle,
       _interval = interval;

  /// Whether a live connection took the frame.
  final bool Function() _send;
  final bool Function() _inCall;
  final bool Function()? _speaking;
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
    if (_speaking?.call() ?? false) return true;
    final idle = _systemIdle?.idleTime();
    if (idle != null && idle < window) return true;
    if (idle != null && idle >= presenceCallIdleLimit) return false;
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

final _localSpeakingProvider = Provider<bool>(
  (ref) => ref.watch(
    voiceParticipantsProvider.select(
      (all) => all.any((p) => p.isLocal && p.isSpeaking),
    ),
  ),
);

/// One source for the whole process: host-wide input is the same for every account, so none polls it again.
final SystemIdle? _processSystemIdle = createSystemIdle();

/// The host's idle source, or null where there is none. Overridden in tests with a fake.
final systemIdleProvider = Provider<SystemIdle?>((ref) => _processSystemIdle);

final presenceActivityReporterProvider = Provider<PresenceActivityReporter>((
  ref,
) {
  final sync = ref.read(syncControllerProvider.notifier);
  final reporter = PresenceActivityReporter(
    send: sync.notifyActive,
    inCall: () =>
        ref.read(voiceFlagsProvider).state == VoiceSessionState.connected,
    speaking: () => ref.read(_localSpeakingProvider),
    systemIdle: ref.read(systemIdleProvider),
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
