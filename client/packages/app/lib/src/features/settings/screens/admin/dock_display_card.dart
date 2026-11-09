// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a module's badges and profile sections show, on the page of a module
/// that declares them. The server keeps one Space-wide flag per kind, so the
/// switch here is shared by every module of that kind and says so.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../../providers/providers.dart';
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../modules/providers/module_display_settings.dart';
import '../../widgets/join_policy_row.dart' show spaceSettingsProvider;
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

/// Draws nothing when [installed] declares neither slot kind.
class DockDisplayCard extends StatelessWidget {
  const DockDisplayCard({super.key, required this.installed});

  final InstalledDockModule installed;

  static bool shows(InstalledDockModule installed) =>
      installed.declaresMemberBadge || installed.declaresProfileSection;

  @override
  Widget build(BuildContext context) {
    if (!shows(installed)) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: 'Display',
      description: 'Applies to every module that shows these.',
      children: [
        if (installed.declaresMemberBadge)
          _DisplayToggle(
            label: 'Show its badges in the member list',
            valueOf: (s) => s.moduleMemberBadges,
            update: (v) => SpaceSettingsUpdate(moduleMemberBadges: v),
          ),
        if (installed.declaresProfileSection)
          _DisplayToggle(
            label: 'Show its sections on profiles',
            valueOf: (s) => s.moduleProfileSections,
            update: (v) => SpaceSettingsUpdate(moduleProfileSections: v),
          ),
      ],
    );
  }
}

class _DisplayToggle extends ConsumerStatefulWidget {
  const _DisplayToggle({
    required this.label,
    required this.valueOf,
    required this.update,
  });

  final String label;
  final bool Function(SpaceSettings) valueOf;
  final SpaceSettingsUpdate Function(bool) update;

  @override
  ConsumerState<_DisplayToggle> createState() => _DisplayToggleState();
}

class _DisplayToggleState extends ConsumerState<_DisplayToggle>
    with
        GuardedActionState<_DisplayToggle>,
        OptimisticSettingState<_DisplayToggle, bool> {
  Future<void> _set(bool value) {
    final container = ProviderScope.containerOf(context, listen: false);
    return saveOptimistic(
      value,
      whatFailed: 'change where module output shows',
      action: () async {
        await container
            .read(apiProvider)
            .setSpaceSettings(widget.update(value));
        container.invalidate(moduleDisplayProvider);
      },
      refresh: spaceSettingsProvider,
    );
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
