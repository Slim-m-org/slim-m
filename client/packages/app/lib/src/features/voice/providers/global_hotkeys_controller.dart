// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Feeds OS-level key presses into [PushToTalkGate] and keeps the OS-side
/// registrations matched to what the person has switched on.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'push_to_talk_gate.dart';
import 'shortcut_overrides.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

const noGlobalCaptureMessage =
    'This works only while slim-m is focused on this system.';
const captureLostMessage =
    'Background capture stopped, so this works only while slim-m is focused.';

/// The chord [action] currently has, which global capture registers too.
HotkeyChord chordFor(AppAction action, HotkeyChord fallback) {
  final activator = activatorFor(action);
  if (activator is! SingleActivator) return fallback;
  return HotkeyChord(
    activator.trigger,
    ctrl: activator.control,
    alt: activator.alt,
    shift: activator.shift,
    meta: activator.meta,
  );
}

HotkeyChord get muteChord => chordFor(
  AppAction.toggleMuteCall,
  const HotkeyChord(LogicalKeyboardKey.keyM, ctrl: true, shift: true),
);

HotkeyChord get deafenChord => chordFor(
  AppAction.toggleDeafenCall,
  const HotkeyChord(LogicalKeyboardKey.keyD, ctrl: true, shift: true),
);

final globalHotkeySourceProvider = Provider<GlobalHotkeySource?>((ref) {
  if (!isDesktopHost) return null;
  final source = createGlobalHotkeySource();
  if (source != null) ref.onDispose(() => unawaited(source.dispose()));
  return source;
});

/// Null while the first check runs; afterwards what settings should say.
class GlobalHotkeysController extends StateNotifier<GlobalHotkeyAvailability?> {
  GlobalHotkeysController(this._ref) : super(null) {
    final source = _ref.read(globalHotkeySourceProvider);
    if (source == null) {
      state = const GlobalHotkeyAvailability.unavailable(
        noGlobalCaptureMessage,
      );
      return;
    }
    _source = source;
    _events = source.events.listen(_onEvent);
    _ref.listen(
      voiceSettingsControllerProvider,
      (_, _) => _sync(retryUnavailable: true),
    );
    _ref.listen(voiceControllerProvider, (_, _) => _sync());
    _ref.listen(
      shortcutOverridesProvider,
      (_, _) => _sync(retryUnavailable: true),
    );
    unawaited(_start());
  }

  final Ref _ref;
  GlobalHotkeySource? _source;
  StreamSubscription<GlobalHotkeyEvent>? _events;
  String _bound = '';
  bool _binding = false;
  bool _probedAvailable = false;

  Future<void> _start() async {
    final source = _source;
    if (source == null) return;
    final probed = await source.probe();
    _probedAvailable = probed.available;
    state = probed;
    if (mounted) await _sync();
  }

  List<GlobalHotkeyBinding> _wanted() {
    final settings = _ref.read(voiceSettingsControllerProvider);
    final inCall =
        _ref.read(voiceControllerProvider).state == VoiceSessionState.connected;
    return [
      if (settings.pushToTalkEnabled)
        GlobalHotkeyBinding(
          id: GlobalHotkeyId.pushToTalk,
          description: 'Push to talk',
          chord: HotkeyChord(settings.pushToTalkKey),
        ),
      if (inCall)
        GlobalHotkeyBinding(
          id: GlobalHotkeyId.toggleMute,
          description: 'Mute or unmute',
          chord: muteChord,
        ),
      if (inCall)
        GlobalHotkeyBinding(
          id: GlobalHotkeyId.toggleDeafen,
          description: 'Deafen or undeafen',
          chord: deafenChord,
        ),
    ];
  }

  String _chordKey(HotkeyChord c) =>
      '${c.key.keyId}${c.ctrl ? 'c' : ''}${c.alt ? 'a' : ''}${c.shift ? 's' : ''}${c.meta ? 'm' : ''}';

  Future<void> _sync({bool retryUnavailable = false}) async {
    final source = _source;
    final canBind =
        state?.available == true || (retryUnavailable && _probedAvailable);
    if (source == null || _binding || !canBind) return;
    final wanted = _wanted();
    final signature = [
      for (final b in wanted) '${b.id.name}:${_chordKey(b.chord)}',
    ].join(',');
    if (signature == _bound) return;
    if (!_ref.read(voiceSettingsControllerProvider).pushToTalkEnabled) {
      _ref.read(pushToTalkGateProvider).reset();
    }
    _binding = true;
    try {
      final result = await source.bind(wanted);
      if (!mounted) return;
      _bound = signature;
      state = result;
    } finally {
      _binding = false;
    }
    if (mounted && state?.available == true) await _sync();
  }

  void _onEvent(GlobalHotkeyEvent event) {
    final gate = _ref.read(pushToTalkGateProvider);
    if (event.phase == GlobalHotkeyPhase.lost) {
      gate.release(HoldSource.global);
      _bound = '';
      state = const GlobalHotkeyAvailability.unavailable(captureLostMessage);
      return;
    }
    switch (event.id) {
      case GlobalHotkeyId.pushToTalk:
        if (!_ref.read(voiceSettingsControllerProvider).pushToTalkEnabled) {
          return;
        }
        if (event.phase == GlobalHotkeyPhase.pressed) {
          gate.press(HoldSource.global);
        } else {
          gate.release(HoldSource.global);
        }
      case GlobalHotkeyId.toggleMute:
        if (event.phase == GlobalHotkeyPhase.pressed) _toggleMute(gate);
      case GlobalHotkeyId.toggleDeafen:
        if (event.phase == GlobalHotkeyPhase.pressed) _toggleDeafen(gate);
      case null:
        return;
    }
  }

  void _toggleMute(PushToTalkGate gate) {
    final voice = _ref.read(voiceControllerProvider.notifier);
    if (voice.state.state != VoiceSessionState.connected) return;
    gate.toggleMute(
      HoldSource.global,
      () => unawaited(voice.toggleMicrophone()),
    );
  }

  void _toggleDeafen(PushToTalkGate gate) {
    final voice = _ref.read(voiceControllerProvider.notifier);
    if (voice.state.state != VoiceSessionState.connected) return;
    gate.toggleDeafen(HoldSource.global, () => unawaited(voice.toggleDeafen()));
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }
}

final globalHotkeysProvider =
    StateNotifierProvider<GlobalHotkeysController, GlobalHotkeyAvailability?>(
      GlobalHotkeysController.new,
    );
