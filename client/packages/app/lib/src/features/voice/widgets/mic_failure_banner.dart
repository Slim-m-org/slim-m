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

class MicFailureBanner extends ConsumerWidget {
  const MicFailureBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
