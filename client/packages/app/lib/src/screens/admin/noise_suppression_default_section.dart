// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's default noise suppression, next to the screen-share ceiling
/// since both shape what a call costs and sounds like.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../providers/providers.dart';
import '../../widgets/join_policy_row.dart' show spaceSettingsProvider;
import '../../widgets/optimistic_setting_state.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class NoiseSuppressionDefaultSection extends ConsumerStatefulWidget {
  const NoiseSuppressionDefaultSection({super.key});

  @override
  ConsumerState<NoiseSuppressionDefaultSection> createState() =>
      _NoiseSuppressionDefaultSectionState();
}

class _NoiseSuppressionDefaultSectionState
    extends ConsumerState<NoiseSuppressionDefaultSection>
    with
        GuardedActionState<NoiseSuppressionDefaultSection>,
        OptimisticSettingState<NoiseSuppressionDefaultSection, bool> {
  Future<void> _set(bool enabled) => saveOptimistic(
    enabled,
    whatFailed: 'change the default noise suppression',
    action: () =>
        ref.read(apiProvider).setSpaceSettings(strongNoiseSuppression: enabled),
    refresh: spaceSettingsProvider,
  );

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final current = optimistic ?? settings.valueOrNull?.strongNoiseSuppression;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Noise suppression',
          description: 'For members who leave it on Space default.',
          children: [
            SettingsToggleRow(
              label: 'Strong by default',
              description: 'Also removes keyboards, fans and room noise.',
              value: current ?? false,
              semanticLabel: 'Strong noise suppression by default',
              onChanged: current == null || saving ? null : _set,
            ),
            if (settings.hasError && current == null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: 'Could not load the current default.',
                    onRetry: () => ref.invalidate(spaceSettingsProvider),
                  ),
                ],
              ),
          ],
        ),
        SettingsSaveFeedback(
          tick: successTick,
          error: actionError,
          onDismissError: clearActionError,
        ),
      ],
    );
  }
}
