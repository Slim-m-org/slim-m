// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells someone in a call why their microphone is not working, and opens the
/// OS page that fixes it where there is one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

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
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s12),
      child: AppErrorState(
        message: advice.message,
        onRetry: settings == null
            ? null
            : () => unawaited(
                openMicSettings(
                  settings,
                  launcher: ref.read(micSettingsLauncherProvider),
                ),
              ),
        retryLabel: 'Open settings',
      ),
    );
  }
}

/// One plain line saying which microphone took over; the choice in Settings is untouched.
class _SwitchedNotice extends ConsumerWidget {
  const _SwitchedNotice(this.label);

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(top: AppSpacing.s12),
    child: AppCallout(
      tone: AppCalloutTone.info,
      icon: AppIcons.mic,
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          Expanded(
            child: Text('Your microphone went silent. Switched to $label.'),
          ),
          AppButton(
            size: AppButtonSize.sm,
            label: 'Dismiss',
            onPressed: ref
                .read(voiceControllerProvider.notifier)
                .devices
                .dismissMicFallbackNotice,
          ),
        ],
      ),
    ),
  );
}
