// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slim one-line stand-in for the call strip while a phone's keyboard is up.
///
/// The full strip would take a second row of the little height the keyboard
/// leaves, so this keeps only the timer, mute and hang up, and sits in the
/// composer's own stack. Width decides when it shows (`kCompactWidth`), never
/// the platform; see `docs/design/desktop-vs-mobile.md` rule 6.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import 'call_participant_tiles.dart';
import 'call_strip_press_area.dart';
import 'voice_strip_indicator.dart';

/// Whether the pill belongs above the composer of [channelId] right now.
bool showsCallKeyboardPill({
  required double width,
  required bool keyboardUp,
  required VoiceSessionState state,
  required String? callChannelId,
  required String channelId,
}) =>
    width < kCompactWidth &&
    keyboardUp &&
    state == VoiceSessionState.connected &&
    callChannelId != channelId;

/// The shell's reading of the keyboard, passed down because the Scaffold in between consumes the inset.
class ShellKeyboard extends InheritedWidget {
  const ShellKeyboard({super.key, required this.up, required super.child});

  final bool up;

  static bool isUp(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellKeyboard>()?.up ?? false;

  @override
  bool updateShouldNotify(ShellKeyboard oldWidget) => up != oldWidget.up;
}

class CallKeyboardPill extends ConsumerWidget {
  const CallKeyboardPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceControllerProvider);
    if (voice.state != VoiceSessionState.connected) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final controller = ref.read(voiceControllerProvider.notifier);
    final channelId = voice.channelId;
    final since = voice.connectedAt;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadii.full),
          border: Border.all(color: tokens.borderSubtle),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
          child: Stack(
            children: [
              if (channelId != null)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.full),
                    child: CallStripPressArea(
                      semanticLabel: 'Return to call',
                      onPressed: () => returnToCall(ref, context, channelId),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.s16),
                child: Row(
                  children: [
                    Expanded(
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: since == null
                              ? const SizedBox.shrink()
                              : CallDuration(since: since),
                        ),
                      ),
                    ),
                    AppIconButton(
                      icon: voice.microphoneEnabled
                          ? AppIcons.mic
                          : AppIcons.micOff,
                      semanticLabel: voice.microphoneEnabled
                          ? 'Mute'
                          : 'Unmute',
                      tooltip: voice.microphoneEnabled ? 'Mute' : 'Unmute',
                      onPressed: controller.toggleMicrophone,
                    ),
                    AppIconButton(
                      icon: AppIcons.leaveCall,
                      semanticLabel: 'Leave call',
                      tooltip: 'Leave call',
                      variant: AppIconButtonVariant.danger,
                      onPressed: controller.leave,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
