// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's microphone button and the muted-state rule it shares with its caret.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show MicStatus;

import '../providers/mic_status.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import 'call_availability.dart' show joinedMutedHint;
import 'call_dock_button.dart';
import 'call_leave_button.dart' show labelWithShortcut;
import 'level_display_hold.dart';

/// The muted (or lost) danger outline, shared by the mic button and its caret.
bool micCallDestructive(WidgetRef ref, VoiceFlags voice, String? listenOnly) {
  final lost =
      ref.watch(micStatusProvider).valueOrNull == MicStatus.unavailable;
  return (!voice.microphoneEnabled || lost) && listenOnly == null;
}

class MicCallButton extends ConsumerWidget {
  const MicCallButton({
    super.key,
    required this.voice,
    required this.listenOnly,
    required this.holdOpensOptions,
    required this.controller,
  });

  final VoiceFlags voice;
  final String? listenOnly;
  final bool holdOpensOptions;
  final VoiceController controller;

  static String _tooltip(VoiceFlags voice) {
    final String label;
    if (voice.microphoneEnabled) {
      label = 'Mute';
    } else {
      label = voice.joinedMuted ? joinedMutedHint : 'Unmute';
    }
    return labelWithShortcut(label, AppAction.toggleMuteCall);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final micStatus = ref.watch(micStatusProvider).valueOrNull ?? MicStatus.ok;
    final speaking = voice.microphoneEnabled && listenOnly == null;
    final trouble = speaking ? micStatus.trouble : null;
    final lost = micStatus == MicStatus.unavailable;
    return LevelDisplayHold(
      active: voice.microphoneEnabled,
      child: CallDockButton(
        icon: speaking && !lost ? AppIcons.mic : AppIcons.micOff,
        tooltip: listenOnly ?? trouble ?? _tooltip(voice),
        // Accent is for tools and modes only; on is plain, muted is the danger outline (decision 0047, point 3).
        active: false,
        pending: micStatus == MicStatus.reconnecting && trouble != null,
        unavailable: listenOnly != null,
        holdOpensOptions: holdOpensOptions,
        destructive: micCallDestructive(ref, voice, listenOnly),
        level: voice.microphoneEnabled
            ? ref.watch(localMicLevelProvider)
            : null,
        onPressed: trouble != null && lost
            ? () => unawaited(controller.resetMicrophone())
            : controller.toggleMicrophone,
      ),
    );
  }
}
