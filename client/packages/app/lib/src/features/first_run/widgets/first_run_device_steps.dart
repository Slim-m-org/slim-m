// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last setup step: what a call uses, laid out like the steps before it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../../settings/widgets/settings_section_header.dart';
import '../../voice/providers/mic_preview.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/widgets/audio_device_section.dart';
import '../../voice/widgets/mic_preview_hold.dart';

/// The level meter holds the capture back until a tap wherever a first capture
/// raises a permission prompt (see `MicPreviewHold`), so this step adds no gate.
class FirstRunVoiceStep extends StatelessWidget {
  const FirstRunVoiceStep({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Devices',
          topGap: kDenseSectionTopGap,
          children: [AudioDeviceSection(embedded: true)],
        ),
        SettingsSectionCard(
          title: 'Your level',
          topGap: kDenseSectionTopGap,
          children: [
            SettingsCardBlock(
              children: [
                MicPreviewHold(
                  tapPadding: EdgeInsets.only(top: AppSpacing.s8),
                  child: _LevelMeter(),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// A call's own level while one is up, the preview's otherwise.
class _LevelMeter extends ConsumerWidget {
  const _LevelMeter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final inCall = ref.watch(
      voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
    );
    final preview = inCall ? null : ref.watch(micMeterProvider);
    final level = preview == null
        ? ref.watch(localMicLevelProvider)
        : preview.fraction;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.s8,
      children: [
        Semantics(
          label: 'Microphone level',
          value: '${(level * 100).round()} percent',
          child: ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.full),
              child: LinearProgressIndicator(
                value: level,
                minHeight: 8,
                color: tokens.accent,
                backgroundColor: tokens.borderSubtle,
              ),
            ),
          ),
        ),
        Text(
          preview?.caption ?? 'Say something to see it move.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}
