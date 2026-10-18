// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first two setup steps: which Space this is, and who the member is in it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/space_banner.dart';
import '../../../widgets/space_icon.dart';
import '../../members/widgets/invite_landing_card.dart'
    show kInviteBannerAspect;
import '../../members/widgets/avatar_settings_section.dart';
import '../../channels/widgets/channel_rail_frame.dart' show serverInfoProvider;
import '../providers/first_run_controller.dart';

const double _iconSize = 56;

class FirstRunWelcomeStep extends ConsumerWidget {
  const FirstRunWelcomeStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final server = ref.watch(serverInfoProvider);
    final inviter = ref.watch(firstRunInviterProvider);
    final loaded = server.valueOrNull;
    if (loaded == null && server.hasError) {
      return AppErrorState(
        message: 'Could not load this Space.',
        onRetry: () => ref.invalidate(serverInfoProvider),
      );
    }
    final description = loaded?.spaceDescription?.trim() ?? '';
    final name = loaded?.displayName ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SpaceBanner(aspect: kInviteBannerAspect),
        if (ref.watch(spaceBannerBytesProvider).valueOrNull != null)
          const SizedBox(height: AppSpacing.s16),
        Row(
          spacing: AppSpacing.s16,
          children: [
            _SpaceMark(iconUpdatedAt: loaded?.iconUpdatedAt, name: name),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.s4,
                children: [
                  Text(
                    name,
                    style: AppText.title.copyWith(color: tokens.textPrimary),
                  ),
                  if (inviter != null)
                    Text(
                      '$inviter invited you.',
                      style: AppText.ui.copyWith(color: tokens.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s16),
          Text(
            description,
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

/// The Space's icon, or its first letter on a tile, so a bare Space still has a mark.
class _SpaceMark extends StatelessWidget {
  const _SpaceMark({required this.iconUpdatedAt, required this.name});

  final int? iconUpdatedAt;
  final String name;

  @override
  Widget build(BuildContext context) {
    final updatedAt = iconUpdatedAt;
    if (updatedAt != null) {
      return SpaceIcon(updatedAt: updatedAt, size: _iconSize);
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final letter = name.isEmpty ? '' : name.characters.first.toUpperCase();
    return SpaceIconFrame(
      size: _iconSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: Center(
          child: Text(
            letter,
            style: AppText.heading.copyWith(
              color: tokens.accent,
              fontWeight: AppWeights.semi,
            ),
          ),
        ),
      ),
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
