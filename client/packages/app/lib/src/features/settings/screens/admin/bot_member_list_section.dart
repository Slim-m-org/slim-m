// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space switch that takes bots out of the member list, beside the bots themselves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../../providers/server_info.dart';
import '../../widgets/join_policy_row.dart' show spaceSettingsProvider;
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class BotMemberListSection extends ConsumerStatefulWidget {
  const BotMemberListSection({super.key});

  @override
  ConsumerState<BotMemberListSection> createState() =>
      _BotMemberListSectionState();
}

class _BotMemberListSectionState extends ConsumerState<BotMemberListSection>
    with
        GuardedActionState<BotMemberListSection>,
        OptimisticSettingState<BotMemberListSection, bool> {
  Future<void> _set(bool hidden) async {
    await saveOptimistic(
      hidden,
      whatFailed: 'change the member list',
      action: () => ref
          .read(apiProvider)
          .setSpaceSettings(SpaceSettingsUpdate(hideBotsInMemberList: hidden)),
      refresh: spaceSettingsProvider,
    );
    ref.invalidate(serverInfoProvider);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final current = optimistic ?? settings.valueOrNull?.hideBotsInMemberList;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Member list',
          children: [
            SettingsToggleRow(
              label: 'Hide bots',
              description: 'They still appear in mentions and voice.',
              value: current ?? false,
              semanticLabel: 'Hide bots from the member list',
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
