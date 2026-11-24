// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Feeds OS-level key presses into [PushToTalkGate] and keeps the OS-side
/// registrations matched to what the person has switched on.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../accounts/providers/account_host.dart';
import '../../accounts/providers/account_providers.dart';
import '../../screen_overlay/providers/call_overlay_toggle.dart';
import '../../screen_overlay/providers/screen_overlay_controller.dart';
import 'call_mark_actions.dart';
import 'call_owner.dart';
import 'push_to_talk_gate.dart';
import 'shortcut_overrides.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

const noGlobalCaptureMessage =
    'This works only while slim-m is focused on this system.';
const captureLostMessage =
    'Background capture stopped, so this works only while slim-m is focused.';

/// The chord [action] currently has, or null once it is unbound or keybinds are off.
HotkeyChord? chordFor(AppAction action) {
  final activator = activatorFor(action);
  if (activator is! SingleActivator) return null;
  return HotkeyChord(
    activator.trigger,
    ctrl: activator.control,
    alt: activator.alt,
    shift: activator.shift,
    meta: activator.meta,
  );
}

GlobalHotkeySource? _processSource;

/// One source for the process: the OS keeps a single native binding set and handler, whichever account is on screen.
final globalHotkeySourceProvider = Provider<GlobalHotkeySource?>((ref) {
  if (!isDesktopHost) return null;
  return _processSource ??= createGlobalHotkeySource();
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
    _owned = ownsCallEvents(_ref);
    _host = _ref.read(accountHostProvider);
    _host?.addListener(_onHostChanged);
    _events = source.events.listen(_onEvent);
    _ref.listen(
      voiceSettingsControllerProvider,
      (_, _) => _sync(retryUnavailable: true),
    );
    _ref.listen(voiceControllerProvider, (_, _) => _sync());
    _ref.listen(screenOverlaySupportedProvider, (_, _) => _sync());
    _ref.listen(
      shortcutOverridesProvider,
      (_, _) => _sync(retryUnavailable: true),
    );
    unawaited(_start());
  }

  final Ref _ref;
  AccountHost? _host;
  bool _owned = true;
  GlobalHotkeySource? _source;
  StreamSubscription<GlobalHotkeyEvent>? _events;
  String _bound = '';
  bool _binding = false;
  bool _probedAvailable = false;

  /// The native binding set is shared, so only the container that owns the call (else the one on screen) binds it.
  void _onHostChanged() {
    final owns = ownsCallEvents(_ref);
    if (owns == _owned) return;
    _owned = owns;
    if (owns) {
      _bound = '';
      unawaited(_sync());
    }
  }

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
    GlobalHotkeyBinding? call(
      GlobalHotkeyId id,
      AppAction action,
      String description,
    ) {
      final chord = inCall ? chordFor(action) : null;
      if (chord == null) return null;
      return GlobalHotkeyBinding(
        id: id,
        description: description,
        chord: chord,
      );
    }

    return [
      if (settings.pushToTalkEnabled)
        GlobalHotkeyBinding(
          id: GlobalHotkeyId.pushToTalk,
          description: 'Push to talk',
          chord: HotkeyChord(settings.pushToTalkKey),
        ),
      ?call(
        GlobalHotkeyId.toggleMute,
        AppAction.toggleMuteCall,
        'Mute or unmute',
      ),
      ?call(
        GlobalHotkeyId.toggleDeafen,
        AppAction.toggleDeafenCall,
        'Deafen or undeafen',
      ),
      ?call(
        GlobalHotkeyId.markCall,
        AppAction.markCallMoment,
        'Mark the moment',
      ),
      if (_ref.read(screenOverlaySupportedProvider))
        ?call(
          GlobalHotkeyId.toggleCallOverlay,
          AppAction.toggleCallOverlay,
          'Show or hide the call overlay',
        ),
    ];
  }

  String _chordKey(HotkeyChord c) =>
      '${c.key.keyId}${c.ctrl ? 'c' : ''}${c.alt ? 'a' : ''}${c.shift ? 's' : ''}${c.meta ? 'm' : ''}';

  Future<void> _sync({bool retryUnavailable = false}) async {
    final source = _source;
    final canBind =
        state?.available == true || (retryUnavailable && _probedAvailable);
    if (source == null || _binding || !canBind || !_owned) return;
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
    if (!_owned) return;
    final gate = _ref.read(pushToTalkGateProvider);
    if (event.phase == GlobalHotkeyPhase.lost) {
      gate.release(HoldSource.global);
      _bound = '';
      state = const GlobalHotkeyAvailability.unavailable(captureLostMessage);
      return;
    }
    // A desktop may keep delivering a shortcut that was dropped from a live session.
    if (!_wanted().any((binding) => binding.id == event.id)) return;
    switch (event.id) {
      case GlobalHotkeyId.pushToTalk:
        if (event.phase == GlobalHotkeyPhase.pressed) {
          gate.press(HoldSource.global);
        } else {
          gate.release(HoldSource.global);
        }
      case GlobalHotkeyId.toggleMute:
        if (event.phase == GlobalHotkeyPhase.pressed) _toggleMute(gate);
      case GlobalHotkeyId.toggleDeafen:
        if (event.phase == GlobalHotkeyPhase.pressed) _toggleDeafen(gate);
      case GlobalHotkeyId.toggleCallOverlay:
        if (event.phase == GlobalHotkeyPhase.pressed) {
          gate.toggleCallOverlay(
            HoldSource.global,
            _ref.read(toggleCallOverlayProvider),
          );
        }
      case GlobalHotkeyId.markCall:
        if (event.phase == GlobalHotkeyPhase.pressed) {
          gate.markCall(
            HoldSource.global,
            () => unawaited(_ref.read(callMarkActionsProvider).mark()),
          );
        }
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
    _host?.removeListener(_onHostChanged);
    unawaited(_events?.cancel());
    super.dispose();
  }
}

final globalHotkeysProvider =
    StateNotifierProvider<GlobalHotkeysController, GlobalHotkeyAvailability?>(
      GlobalHotkeysController.new,
    );
