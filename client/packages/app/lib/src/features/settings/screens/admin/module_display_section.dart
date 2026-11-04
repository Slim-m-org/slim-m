// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space-wide switches for where module output shows, behind a single row
/// on the module list.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../modules/providers/module_display_settings.dart';
import '../../widgets/join_policy_row.dart' show spaceSettingsProvider;
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

/// The one row on the module list that opens [showModuleDisplaySheet].
class ModuleDisplayRow extends StatelessWidget {
  const ModuleDisplayRow({super.key});

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    children: [
      SettingsDetailRow(
        icon: AppIcons.settings,
        title: 'Module display',
        detail: 'Where module badges and stats show.',
        onTap: () => unawaited(showModuleDisplaySheet(context)),
        onTapSemanticLabel: 'Module display',
        trailing: const ExcludeSemantics(child: Icon(AppIcons.chevronRight)),
      ),
    ],
  );
}

Future<void> showModuleDisplaySheet(BuildContext context) => showAppSheet<void>(
  context,
  scrolls: true,
  builder: (context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Module display',
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const ModuleDisplaySection(),
        ],
      ),
    );
  },
);

class ModuleDisplaySection extends StatelessWidget {
  const ModuleDisplaySection({super.key});

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    children: [
      _DisplayToggle(
        label: 'Badges in member list',
        description: 'Shows module badges beside names, for everyone.',
        valueOf: (s) => s.moduleMemberBadges,
        update: (v) => SpaceSettingsUpdate(moduleMemberBadges: v),
      ),
      _DisplayToggle(
        label: 'Sections on profiles',
        description: 'Shows module levels and stats on profile cards.',
        valueOf: (s) => s.moduleProfileSections,
        update: (v) => SpaceSettingsUpdate(moduleProfileSections: v),
      ),
    ],
  );
}

class _DisplayToggle extends ConsumerStatefulWidget {
  const _DisplayToggle({
    required this.label,
    required this.description,
    required this.valueOf,
    required this.update,
  });

  final String label;
  final String description;
  final bool Function(SpaceSettings) valueOf;
  final SpaceSettingsUpdate Function(bool) update;

  @override
  ConsumerState<_DisplayToggle> createState() => _DisplayToggleState();
}

class _DisplayToggleState extends ConsumerState<_DisplayToggle>
    with
        GuardedActionState<_DisplayToggle>,
        OptimisticSettingState<_DisplayToggle, bool> {
  Future<void> _set(bool value) async {
    await saveOptimistic(
      value,
      whatFailed: 'change ${widget.label.toLowerCase()}',
      action: () =>
          ref.read(apiProvider).setSpaceSettings(widget.update(value)),
      refresh: spaceSettingsProvider,
    );
    ref.invalidate(moduleDisplayProvider);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final current =
        optimistic ?? settings.whenOrNull(data: (s) => widget.valueOf(s));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: widget.label,
          description: widget.description,
          value: current ?? false,
          semanticLabel: widget.label,
          onChanged: current == null || saving ? null : _set,
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
