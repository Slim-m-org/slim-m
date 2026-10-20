// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space switch for whether any member may invite, beside who may join.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../channels/widgets/channel_rail_frame.dart'
    show serverInfoProvider;
import '../../widgets/join_policy_row.dart' show spaceSettingsProvider;
import '../../../../widgets/optimistic_setting_state.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_save_feedback.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class MemberInvitesSection extends ConsumerStatefulWidget {
  const MemberInvitesSection({super.key});

  @override
  ConsumerState<MemberInvitesSection> createState() =>
      _MemberInvitesSectionState();
}

class _MemberInvitesSectionState extends ConsumerState<MemberInvitesSection>
    with
        GuardedActionState<MemberInvitesSection>,
        OptimisticSettingState<MemberInvitesSection, bool> {
  Future<void> _set(bool enabled) async {
    await saveOptimistic(
      enabled,
      whatFailed: 'change who can invite',
      action: () =>
          ref.read(apiProvider).setSpaceSettings(membersCanInvite: enabled),
      refresh: spaceSettingsProvider,
    );
    ref.invalidate(serverInfoProvider);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    ref.listen(spaceSettingsProvider, (_, next) => retireOptimistic(next));
    final current = optimistic ?? settings.valueOrNull?.membersCanInvite;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Who can invite',
          children: [
            SettingsToggleRow(
              label: 'Members can invite',
              description: 'Any member can make a one-use link for a day.',
              value: current ?? false,
              semanticLabel: 'Let every member invite friends',
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
