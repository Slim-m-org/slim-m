// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One Space-wide on/off setting as its own card: optimistic, saved through
/// PATCH /space/settings, and read back from that route.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/server_info.dart';
import '../../../widgets/optimistic_setting_state.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/settings_actions.dart';
import 'join_policy_row.dart' show spaceSettingsProvider;
import 'settings_save_feedback.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';

class SpaceSettingSwitchSection extends ConsumerStatefulWidget {
  const SpaceSettingSwitchSection({
    super.key,
    required this.title,
    required this.label,
    required this.description,
    required this.semanticLabel,
    required this.whatFailed,
    required this.read,
    required this.update,
  });

  final String title;
  final String label;
  final String description;
  final String semanticLabel;

  /// Finishes "Could not ..." when the save is refused.
  final String whatFailed;
  final bool Function(SpaceSettings settings) read;
  final SpaceSettingsUpdate Function(bool value) update;

  @override
  ConsumerState<SpaceSettingSwitchSection> createState() =>
      _SpaceSettingSwitchSectionState();
}

class _SpaceSettingSwitchSectionState
    extends ConsumerState<SpaceSettingSwitchSection>
    with
        GuardedActionState<SpaceSettingSwitchSection>,
        OptimisticSettingState<SpaceSettingSwitchSection, bool> {
  Future<void> _set(bool value) async {
    await saveOptimistic(
      value,
      whatFailed: widget.whatFailed,
      action: () => ref
          .read(settingsActionsProvider)
          .setSpaceSettings(widget.update(value)),
      refresh: spaceSettingsProvider,
    );
    ref.invalidate(serverInfoProvider);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final stored = settings.valueOrNull;
    final current = optimistic ?? (stored == null ? null : widget.read(stored));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: widget.title,
          children: [
            SettingsToggleRow(
              label: widget.label,
              description: widget.description,
              value: current ?? false,
              semanticLabel: widget.semanticLabel,
              onChanged: current == null || saving ? null : _set,
            ),
            if (settings.hasError && current == null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: 'Could not load the current setting.',
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
