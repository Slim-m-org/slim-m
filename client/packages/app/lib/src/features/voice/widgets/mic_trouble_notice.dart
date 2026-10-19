// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line under a microphone meter when it will not open, with the one tap
/// that fixes it where the OS has a page for it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/settings_info_line.dart';
import '../providers/mic_failure_advice.dart';
import '../providers/mic_failure_providers.dart';

class MicTroubleNotice extends ConsumerWidget {
  const MicTroubleNotice({
    super.key,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.s16,
      vertical: 10,
    ),
  });

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advice = ref.watch(micPreviewAdviceProvider).valueOrNull;
    if (advice == null) return const SizedBox.shrink();
    final settings = advice.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsInfoLine(advice.message, padding: padding),
        if (settings != null)
          Padding(
            padding: EdgeInsets.only(
              left: padding.resolve(Directionality.of(context)).left,
              bottom: AppSpacing.s8,
            ),
            child: AppButton(
              size: AppButtonSize.sm,
              label: 'Open settings',
              onPressed: () => unawaited(
                openMicSettings(
                  settings,
                  launcher: ref.read(micSettingsLauncherProvider),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
