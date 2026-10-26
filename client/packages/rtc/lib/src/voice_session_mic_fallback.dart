// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s device log lines and the switch to another microphone
/// once the watchdog has given up on the one in use; nothing here is saved.
mixin VoiceSessionMicFallback {
  AudioDeviceSwitching get _audioSwitching;
  lk.Room? get _room;
  bool get _micWanted;
  MicPort get _mic;
  MicRecoveryTiming get _micTiming;
  SilentMicWatchdog get _micWatchdog;
  void _logMic(String message, {LogLevel level = LogLevel.info});
  void _setMicStatus(MicStatus next);
  Future<void> _noteMicFailure(MicFailureReason reason);
  Future<bool> _restartMicCapture(String reason);
  Future<bool> selectAudioInputDevice(AudioDevice? device);
  Future<bool> selectAudioOutputDevice(AudioDevice? device);

  /// Whether a silent microphone is swapped for another; see [setMicFallbackEnabled].
  bool micFallbackEnabled = true;
  bool _fallingBack = false;
  final _fallbackTried = <String>{};
  String? _loggedInputNames;
  String? _micFallbackNotice;
  final _micFallbackNotices = StreamController<String?>.broadcast();

  /// The microphone the call switched to on its own, until dismissed.
  String? get micFallbackNotice => _micFallbackNotice;
  Stream<String?> get micFallbackNotices => _micFallbackNotices.stream;

  void setMicFallbackEnabled(bool enabled) => micFallbackEnabled = enabled;

  void dismissMicFallbackNotice() => _setFallbackNotice(null);

  void _setFallbackNotice(String? next) {
    if (next == _micFallbackNotice) return;
    _micFallbackNotice = next;
    if (!_micFallbackNotices.isClosed) _micFallbackNotices.add(next);
  }

  // ignore: unused_element, called through the recovery mixin
  void _resetMicFallback() {
    _fallbackTried.clear();
    _loggedInputNames = null;
    _setFallbackNotice(null);
  }

  // ignore: unused_element, called through the recovery mixin
  Future<void> _disposeMicFallback() => _micFallbackNotices.close();

  /// The chosen microphone and speaker, as labels and ids, for a tester's log.
  Future<void> _logAudioDevices(String why) async {
    try {
      final mic = await _audioSwitching.inputDeviceInUse();
      final speaker = await _audioSwitching.outputDeviceInUse();
      _logMic(
        'Audio devices ($why): mic ${describeDevice(mic, followsDefault: _audioSwitching.followsSystemDefaultInput)}; '
        'speaker ${describeDevice(speaker, followsDefault: _audioSwitching.followsSystemDefaultOutput)}',
      );
    } on Object catch (e) {
      _logMic('Could not read the audio devices: $e', level: LogLevel.warning);
    }
  }

  /// Logs the microphone names once, and again whenever the list changes.
  // ignore: unused_element, called through the recovery mixin
  Future<void> _logInputList() async {
    try {
      final names = [
        for (final d in await _audioSwitching.inputs())
          d.label.isEmpty ? 'unnamed' : d.label,
      ].join(' | ');
      if (names == _loggedInputNames) return;
      _loggedInputNames = names;
      _logMic('Microphones: ${names.isEmpty ? 'none listed' : names}');
    } on Object catch (e) {
      _logMic('Could not list microphones: $e', level: LogLevel.warning);
    }
  }

  /// Tries each other microphone once, the system default first; keeps the
  /// first that is not silent, and leaves the mic unavailable otherwise.
  // ignore: unused_element, called through the recovery mixin
  Future<void> _fallBackMic() async {
    if (_fallingBack || _room == null || !_micWanted) return;
    _fallingBack = true;
    try {
      await _tryFallbacks();
    } on Object catch (e) {
      _logMic('Microphone fallback failed: $e', level: LogLevel.warning);
      _failFallback();
    } finally {
      _fallingBack = false;
    }
  }

  Future<void> _tryFallbacks() async {
    _fallbackTried.add(fallbackKey(_audioSwitching.inputInUse));
    await _followSystemOutput();
    final candidates = fallbackCandidates(
      inputs: await _audioSwitching.inputs(),
      inUseId: _audioSwitching.inputInUse,
      tried: _fallbackTried,
    );
    for (final candidate in candidates) {
      _fallbackTried.add(fallbackKey(candidate?.id));
      if (await _tryFallback(candidate)) return;
    }
    _logMic(
      'No other microphone worked; leaving the microphone unavailable',
      level: LogLevel.warning,
    );
    _failFallback();
  }

  Future<void> _followSystemOutput() async {
    if (_audioSwitching.followsSystemDefaultOutput) return;
    if (await selectAudioOutputDevice(null)) {
      _logMic('Speaker moved back to the system default');
    }
  }

  Future<bool> _tryFallback(AudioDevice? candidate) async {
    final target = candidate?.label ?? 'the system default';
    _logMic('Switching microphone to $target for this call only');
    if (!await selectAudioInputDevice(candidate)) return false;
    await _restartMicCapture('fallback');
    await Future<void>.delayed(_micTiming.fallbackSettle);
    final sent = await _sentLevel();
    if (sent != null && sent <= kInputFloorDb + 1) {
      _logMic('Microphone $target is silent too', level: LogLevel.warning);
      return false;
    }
    final shown = await _audioSwitching.inputDeviceInUse();
    _logMic('Microphone fallback worked: $target');
    await _logAudioDevices('fallback');
    _micWatchdog.reset();
    _setMicStatus(MicStatus.ok);
    _setFallbackNotice(shown?.label ?? target);
    return true;
  }

  Future<double?> _sentLevel() async {
    try {
      return await _mic.senderLevelDb();
    } on Object {
      return null;
    }
  }

  void _failFallback() {
    _setMicStatus(MicStatus.unavailable);
    unawaited(_noteMicFailure(MicFailureReason.silent));
  }
}
