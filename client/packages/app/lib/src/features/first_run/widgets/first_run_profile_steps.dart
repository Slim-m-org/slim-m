// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first two setup steps: which Space this is, and who the member is in it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/space_icon.dart';
import '../../members/widgets/avatar_settings_section.dart';
import '../../settings/widgets/join_policy_row.dart' show spaceSettingsProvider;
import '../providers/first_run_controller.dart';

const double _iconSize = 56;

class FirstRunWelcomeStep extends ConsumerWidget {
  const FirstRunWelcomeStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final settings = ref.watch(spaceSettingsProvider);
    final inviter = ref.watch(firstRunInviterProvider);
    final loaded = settings.valueOrNull;
    if (loaded == null && settings.hasError) {
      return AppErrorState(
        message: 'Could not load this Space.',
        onRetry: () => ref.invalidate(spaceSettingsProvider),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SpaceMark(settings: loaded),
        const SizedBox(height: AppSpacing.s16),
        Text(
          loaded?.name ?? '',
          style: AppText.title.copyWith(color: tokens.textPrimary),
        ),
        if (inviter != null) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            '$inviter invited you.',
            style: AppText.ui.copyWith(color: tokens.textSecondary),
          ),
        ],
        if (loaded != null && loaded.description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s12),
          Text(
            loaded.description,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ],
        const SizedBox(height: AppSpacing.s16),
        Text(
          'A few quick choices, and you can change all of them later.',
          style: AppText.ui.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}

class _SpaceMark extends StatelessWidget {
  const _SpaceMark({required this.settings});

  final api.SpaceSettings? settings;

  @override
  Widget build(BuildContext context) {
    final updatedAt = settings?.iconUpdatedAt;
    if (updatedAt != null) {
      return SpaceIcon(updatedAt: updatedAt, size: _iconSize);
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SpaceIconFrame(
      size: _iconSize,
      child: Icon(AppIcons.hash, size: 28, color: tokens.textSecondary),
    );
  }
}

class FirstRunYouStep extends StatelessWidget {
  const FirstRunYouStep({super.key, required this.pronouns});

  final TextEditingController pronouns;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AvatarSettingsSection(),
        const SizedBox(height: AppSpacing.s16),
        Text(
          'Pronouns (optional)',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s4),
        AppInput(
          controller: pronouns,
          maxLength: api.InputLimits.pronouns,
          placeholder: 'e.g. she/her',
          semanticLabel: 'Pronouns',
        ),
      ],
    );
  }
}
