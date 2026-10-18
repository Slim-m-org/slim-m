// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space-wide switch for link preview cards, on the retention and limits
/// pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../channels/widgets/channel_rail_frame.dart'
    show serverInfoProvider;
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class LinkPreviewsSection extends ConsumerStatefulWidget {
  const LinkPreviewsSection({super.key});

  @override
  ConsumerState<LinkPreviewsSection> createState() =>
      _LinkPreviewsSectionState();
}

class _LinkPreviewsSectionState extends ConsumerState<LinkPreviewsSection>
    with
        GuardedActionState<LinkPreviewsSection>,
        OptimisticSettingState<LinkPreviewsSection, bool> {
  Future<void> _set(bool enabled) async {
    await saveOptimistic(
      enabled,
      whatFailed: 'change link previews',
      action: () => ref.read(apiProvider).setSpaceLinkPreviews(enabled),
      refresh: spaceLinkPreviewsProvider,
    );
    ref.invalidate(serverInfoProvider);
  }

  @override
  Widget build(BuildContext context) {
    final setting = ref.watch(spaceLinkPreviewsProvider);
    ref.listen(spaceLinkPreviewsProvider, (_, next) => retireOptimistic(next));
    final current = optimistic ?? setting.valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Link previews',
          description: 'Cards under messages that contain a link.',
          children: [
            SettingsToggleRow(
              label: 'Preview links',
              description: 'The server fetches each page to build its card.',
              value: current ?? false,
              semanticLabel: 'Preview links for the whole Space',
              onChanged: current == null || saving ? null : _set,
            ),
            if (setting.hasError && current == null)
              SettingsCardBlock(
                children: [
                  AppErrorState(
                    message: 'Could not load the current setting.',
                    onRetry: () => ref.invalidate(spaceLinkPreviewsProvider),
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
