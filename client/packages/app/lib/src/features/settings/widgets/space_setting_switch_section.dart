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
import '../providers/space_settings.dart';
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
    this.unavailableReason,
    this.isAvailable,
  });

  final String title;
  final String label;
  final String description;
  final String semanticLabel;

  /// Finishes "Could not ..." when the save is refused.
  final String whatFailed;
  final bool Function(SpaceSettings settings) read;
  final SpaceSettingsUpdate Function(bool value) update;

  /// Said under the switch, which is then off and disabled, when [isAvailable] answers false.
  final String? unavailableReason;
  final bool Function(SpaceSettings settings)? isAvailable;

  @override
  ConsumerState<SpaceSettingSwitchSection> createState() =>
      _SpaceSettingSwitchSectionState();
}

class _SpaceSettingSwitchSectionState
    extends ConsumerState<SpaceSettingSwitchSection>
    with
        GuardedActionState<SpaceSettingSwitchSection>,
        OptimisticSettingState<SpaceSettingSwitchSection, bool> {
  Future<void> _set(bool value) {
    final container = ProviderScope.containerOf(context, listen: false);
    return saveOptimistic(
      value,
      whatFailed: widget.whatFailed,
      action: () async {
        await container
            .read(settingsActionsProvider)
            .setSpaceSettings(widget.update(value));
        container.invalidate(serverInfoProvider);
      },
      refresh: spaceSettingsProvider,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final stored = settings.valueOrNull;
    final current = optimistic ?? (stored == null ? null : widget.read(stored));
    final available =
        stored == null || (widget.isAvailable?.call(stored) ?? true);

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
              onChanged: current == null || saving || !available ? null : _set,
            ),
            if (!available && widget.unavailableReason != null)
              SettingsSubRow(label: widget.unavailableReason!),
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
