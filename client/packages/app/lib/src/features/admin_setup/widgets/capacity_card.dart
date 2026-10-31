// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this server is and what it can carry, as the server reports it.
/// Shown in the admin setup and again in Server metrics.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../providers/admin_setup_controller.dart';
import '../providers/capacity_guidance.dart';

class CapacityCard extends ConsumerWidget {
  const CapacityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(spaceSetupProvider);
    return setup.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) => SettingsSectionCard(
        title: 'This server',
        children: [
          SettingsCardBlock(
            children: [
              AppErrorState(
                message: 'Could not load this server\'s capacity.',
                onRetry: () => ref.invalidate(spaceSetupProvider),
              ),
            ],
          ),
        ],
      ),
      data: (loaded) => _Loaded(capacity: loaded.capacity),
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({required this.capacity});

  final api.SpaceCapacity capacity;

  @override
  Widget build(BuildContext context) {
    final estimate = capacity.estimate;
    return SettingsSectionCard(
      title: 'This server',
      description: 'Estimates from load tests, a range and not a promise.',
      children: [
        SettingsDetailRow(
          icon: AppIcons.storage,
          title: 'Machine',
          detail: machineSummary(capacity),
        ),
        SettingsDetailRow(
          icon: AppIcons.members,
          title: 'People',
          detail: '${membersSummary(estimate)} ${limitSummary(estimate)}',
        ),
        SettingsDetailRow(
          icon: AppIcons.voice,
          title: 'Voice',
          detail: voiceSummary(capacity),
        ),
        SettingsDetailRow(
          icon: AppIcons.externalLink,
          title: 'How these are worked out',
          detail: 'The measurements and assumptions behind the range.',
          onTap: () => unawaited(openExternalHttpUrl(capacityGuidanceUrl)),
        ),
      ],
    );
  }
}

/// One recommendation tied to this machine, shown beside the setting it is about.
class SetupTipNote extends StatelessWidget {
  const SetupTipNote({required this.tip, super.key});

  final SetupTip tip;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s8,
        children: [
          Icon(AppIcons.info, size: AppSizes.icon16, color: tokens.accent),
          Expanded(
            child: Text(
              tip.text,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every tip for this machine in one card, so the first step previews what the rest suggest.
class SetupTipsCard extends ConsumerWidget {
  const SetupTipsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capacity = ref.watch(spaceSetupProvider).valueOrNull?.capacity;
    if (capacity == null) return const SizedBox.shrink();
    final tips = setupTips(capacity);
    if (tips.isEmpty) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: 'Suggested for this server',
      children: [
        for (final tip in tips)
          SettingsDetailRow(
            icon: AppIcons.performance,
            title: tip.target.label,
            detail: tip.text,
          ),
      ],
    );
  }
}
