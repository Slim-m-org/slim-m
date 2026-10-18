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
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

const noGlobalCaptureMessage =
    'This works only while slim-m is focused on this system.';
const captureLostMessage =
    'Background capture stopped, so this works only while slim-m is focused.';

/// The shortcut the mute row shows; global capture registers the same chord.
HotkeyChord get muteChord {
  final activator = activatorFor(AppAction.toggleMuteCall);
  if (activator is! SingleActivator) {
    return const HotkeyChord(LogicalKeyboardKey.keyM, ctrl: true, shift: true);
  }
  return HotkeyChord(
    activator.trigger,
    ctrl: activator.control,
    alt: activator.alt,
    shift: activator.shift,
    meta: activator.meta,
  );
}

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
    _ref.listen(voiceSettingsControllerProvider, (_, _) => _sync());
    _ref.listen(voiceControllerProvider, (_, _) => _sync());
    unawaited(_start());
  }

  final Ref _ref;
  GlobalHotkeySource? _source;
  StreamSubscription<GlobalHotkeyEvent>? _events;
  String _bound = '';
  bool _binding = false;

  Future<void> _start() async {
    final source = _source;
    if (source == null) return;
    state = await source.probe();
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
    ];
  }

  Future<void> _sync() async {
    final source = _source;
    if (source == null || _binding || state?.available != true) return;
    final wanted = _wanted();
    final signature = [
      for (final b in wanted) '${b.id.name}:${b.chord.key.keyId}',
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
