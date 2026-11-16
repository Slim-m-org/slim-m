// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slim one-line stand-in for the call strip while a phone's keyboard is up.
///
/// The full strip would take a second row of the little height the keyboard
/// leaves, so this keeps only the timer, mute and hang up, and sits in the
/// composer's own stack. Width decides when it shows (`kCompactWidth`), never
/// the platform; see `docs/design/desktop-vs-mobile.md` rule 6.
///
/// With no call here it shows another community's call, its name ahead of the
/// timer, so the floating call pill steps aside (decision 0068).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../accounts/providers/account_providers.dart';
import '../../accounts/widgets/call_elsewhere_view.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
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
  required bool callElsewhere,
}) =>
    width < kCompactWidth &&
    keyboardUp &&
    (state == VoiceSessionState.connected
        ? callChannelId != channelId
        : callElsewhere);

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

  static const Key pillKey = Key('call_keyboard_pill');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voice = ref.watch(voiceFlagsProvider);
    if (voice.state != VoiceSessionState.connected) {
      final elsewhere = ref.watch(accountsSnapshotProvider).callElsewhere;
      if (elsewhere == null) return const SizedBox.shrink();
      return CallElsewhereView(
        entry: elsewhere,
        builder: (context, call) => _Pill(
          press: CallStripPressArea(
            semanticLabel: call.returnLabel,
            onPressed: () => unawaited(call.open()),
          ),
          summary: _CommunityClock(
            community: call.community,
            since: call.voice.connectedAt,
          ),
          voice: call.voice,
          controller: call.controller,
        ),
      );
    }
    final channelId = voice.channelId;
    final since = voice.connectedAt;
    return _Pill(
      press: switch (channelId) {
        final channelId? => CallStripPressArea(
          semanticLabel: 'Return to call',
          onPressed: () => returnToCall(ref, context, channelId),
        ),
        null => null,
      },
      summary: since == null
          ? const SizedBox.shrink()
          : CallDuration(since: since),
      voice: voice,
      controller: ref.read(voiceControllerProvider.notifier),
    );
  }
}

/// The pill's fill, its press surface, and [summary] beside mute and leave,
/// which act on [controller]'s call.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.press,
    required this.summary,
    required this.voice,
    required this.controller,
  });

  final Widget? press;
  final Widget summary;
  final VoiceFlags voice;
  final VoiceController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final muteLabel = voice.microphoneEnabled ? 'Mute' : 'Unmute';
    return Padding(
      key: CallKeyboardPill.pillKey,
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
              if (press case final press?)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.full),
                    child: press,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.s16),
                child: Row(
                  children: [
                    Expanded(
                      child: IgnorePointer(
                        child: ExcludeSemantics(child: summary),
                      ),
                    ),
                    AppIconButton(
                      icon: voice.microphoneEnabled
                          ? AppIcons.mic
                          : AppIcons.micOff,
                      semanticLabel: muteLabel,
                      tooltip: muteLabel,
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

/// The other community's name, cut short before its separator, then the clock.
class _CommunityClock extends StatelessWidget {
  const _CommunityClock({required this.community, required this.since});

  final String community;
  final DateTime? since;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.caption.copyWith(color: tokens.textSecondary);
    return Row(
      children: [
        Flexible(
          child: Text(
            community,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textWidthBasis: TextWidthBasis.longestLine,
            style: style,
          ),
        ),
        if (since case final since?) ...[
          Text(' · ', style: style),
          CallDuration(since: since),
        ],
      ],
    );
  }
}
