// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin setup's step bodies. Each embeds the same section the Space
/// settings pane holds, so a change here is the same write to the same audited
/// route, not a second copy of the control.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../members/widgets/invite_landing_section.dart';
import '../../settings/screens/admin/attachment_limit_section.dart';
import '../../settings/screens/admin/media_compression_section.dart';
import '../../settings/screens/admin/noise_suppression_default_section.dart';
import '../../settings/screens/admin/retention_section.dart';
import '../../settings/screens/admin/screen_share_cap_section.dart';
import '../../settings/widgets/join_gate_section.dart';
import '../../settings/widgets/join_policy_row.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../providers/admin_setup_controller.dart';
import '../providers/capacity_guidance.dart';
import '../widgets/capacity_card.dart';

enum AdminSetupStep {
  server('Your server', 'What this machine can carry, and what to set first.'),
  profile('Name your Space', 'The name, icon and banner people see.'),
  joining('Who can join', 'How people get in.'),
  media('Uploads', 'Shrink photos so storage lasts longer.'),
  retention('Retention and limits', 'Keep storage in check.'),
  voice('Voice defaults', 'How calls and screen shares start.');

  const AdminSetupStep(this.title, this.subtitle);

  final String title;
  final String subtitle;
}

class AdminSetupStepBody extends ConsumerWidget {
  const AdminSetupStepBody({required this.step, super.key});

  final AdminSetupStep step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capacity = ref.watch(spaceSetupProvider).valueOrNull?.capacity;
    List<Widget> tips(SetupTipTarget target) => [
      if (capacity != null)
        for (final tip in tipsFor(target, capacity)) SetupTipNote(tip: tip),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (step) {
        AdminSetupStep.server => const [CapacityCard(), SetupTipsCard()],
        AdminSetupStep.profile => const [InviteLandingSection()],
        AdminSetupStep.joining => const [
          SettingsSectionCard(title: 'Joining', children: [JoinPolicyRow()]),
          JoinGateSection(),
        ],
        AdminSetupStep.media => [
          ...tips(SetupTipTarget.media),
          const MediaCompressionSection(),
        ],
        AdminSetupStep.retention => [
          ...tips(SetupTipTarget.retention),
          const RetentionSection(),
          const AttachmentLimitSection(),
        ],
        AdminSetupStep.voice => [
          ...tips(SetupTipTarget.voice),
          const ScreenShareCapSection(),
          const NoiseSuppressionDefaultSection(),
        ],
      },
    );
  }
}
