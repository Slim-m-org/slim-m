// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one place a push-to-talk hold or a mute toggle is decided, whichever
/// source saw the key.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_lock_controller.dart';
import '../../composer/providers/composer_focus.dart';
import 'voice_controller.dart';

/// Who saw the key: this window's key handler, or the OS-level capture.
enum HoldSource { inWindow, global }

/// Both sources fire for one physical press while the window is focused.
const muteDuplicateWindow = Duration(milliseconds: 300);

class PushToTalkGate {
  PushToTalkGate(
    this._ref, {
    DateTime Function() now = DateTime.now,
    bool Function()? windowFocused,
  }) : _now = now,
       _windowFocused = windowFocused ?? _bindingWindowFocused;

  final Ref _ref;
  final DateTime Function() _now;
  final bool Function() _windowFocused;
  final _holds = <HoldSource>{};
  (HoldSource, DateTime)? _lastMute;

  static bool _bindingWindowFocused() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  VoiceController get _voice => _ref.read(voiceControllerProvider.notifier);

  /// Opens the mic for the first source to hold; a repeat from the same source is ignored.
  void press(HoldSource source) {
    if (_holds.contains(source)) return;
    // A locked app takes no input, and the composer owns the key while it has focus.
    if (_ref.read(appLockControllerProvider)) return;
    final composerFocused =
        _ref.read(composerFocusNodeProvider)?.hasFocus ?? false;
    if (composerFocused && _windowFocused()) return;
    final first = _holds.isEmpty;
    _holds.add(source);
    if (first) unawaited(_voice.setPushToTalkHeld(true));
  }

  /// Closes the mic once no source is holding any more.
  void release(HoldSource source) {
    if (!_holds.remove(source)) return;
    if (_holds.isEmpty) unawaited(_voice.setPushToTalkHeld(false));
  }

  /// Forgets every hold without touching the mic, for when push-to-talk is switched off.
  void reset() => _holds.clear();

  /// Runs [toggle] unless the other source already toggled for this press.
  void toggleMute(HoldSource source, VoidCallback toggle) {
    final now = _now();
    final last = _lastMute;
    if (last != null &&
        last.$1 != source &&
        now.difference(last.$2) < muteDuplicateWindow) {
      return;
    }
    _lastMute = (source, now);
    toggle();
  }
}

final pushToTalkGateProvider = Provider<PushToTalkGate>(PushToTalkGate.new);
