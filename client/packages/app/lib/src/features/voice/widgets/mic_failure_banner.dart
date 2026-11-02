// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells someone in a call why their microphone is not working, and opens the
/// OS page that fixes it where there is one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';
import '../providers/mic_failure_advice.dart';
import '../providers/mic_failure_providers.dart';
import '../providers/voice_controller.dart';

class MicFailureBanner extends ConsumerWidget {
  const MicFailureBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final switched = ref.watch(micFallbackNoticeProvider).valueOrNull;
    if (switched != null) return _SwitchedNotice(switched);
    final reason = ref.watch(micFailureProvider).valueOrNull;
    final advice = reason == null ? null : micAdviceFor(reason);
    if (advice == null) return const SizedBox.shrink();
    final settings = advice.settings;
    return StatusBanner(
      severity: BannerSeverity.error,
      message: advice.message,
      margin: const EdgeInsets.only(top: AppSpacing.s12),
      action: settings == null
          ? null
          : AppButton(
              size: AppButtonSize.sm,
              label: 'Open settings',
              onPressed: () => unawaited(
                openMicSettings(
                  settings,
                  launcher: ref.read(micSettingsLauncherProvider),
                ),
              ),
            ),
    );
  }
}

/// One plain line saying which microphone took over; the choice in Settings is untouched.
class _SwitchedNotice extends ConsumerWidget {
  const _SwitchedNotice(this.label);

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) => StatusBanner(
    icon: AppIcons.mic,
    message: 'Your microphone went silent. Switched to $label.',
    margin: const EdgeInsets.only(top: AppSpacing.s12),
    onDismiss: ref
        .read(voiceControllerProvider.notifier)
        .devices
        .dismissMicFallbackNotice,
  );
}
