// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a previewed role can do in one channel, in place of its messages: a yes or no per
/// permission that applies to the channel's kind.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../widgets/permission_row.dart';
import '../../channels/widgets/channel_kind_icon.dart';

/// The permission bits worth showing for [channel]: call bits only where a call runs, canvas bits only where a board exists.
List<int> rolePreviewBits(api.RolePreviewChannel channel) {
  final board = channel.isCanvasChannel;
  final textLike = !channel.isVoice && !board;
  return [
    Perm.viewChannel,
    if (channel.hostsCall) ...[Perm.connect, Perm.speak, Perm.useSoundboard],
    if (channel.hasCanvas) Perm.useCanvas,
    Perm.sendMessages,
    if (textLike || board) ...[Perm.attachFiles, Perm.addReactions],
    if (textLike) ...[Perm.mentionEveryone, Perm.manageMessages],
    if (channel.hostsCall) Perm.moveMembers,
  ];
}

class RolePreviewSummary extends StatelessWidget {
  const RolePreviewSummary({
    super.key,
    required this.roleName,
    required this.channel,
    this.onBack,
  });

  final String roleName;
  final api.RolePreviewChannel channel;

  /// Shown as a back button on a phone, where the summary replaced the list.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final gutter = compact ? AppSizes.paneGutterCompact : AppSizes.paneGutter;
    final bits = rolePreviewBits(channel);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: AppSizes.headerBar,
          padding: EdgeInsets.symmetric(horizontal: gutter),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
          ),
          child: Row(
            spacing: AppSpacing.s8,
            children: [
              if (onBack != null)
                AppIconButton(
                  icon: AppIcons.back,
                  semanticLabel: 'Back to channels',
                  onPressed: onBack,
                ),
              ChannelKindIcon(
                glyph: ChannelGlyphKind.of(channel.kind),
                restricted: channel.restricted,
                color: tokens.textSecondary,
                size: AppSizes.icon20,
              ),
              Expanded(
                child: Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              gutter,
              AppSpacing.s16,
              gutter,
              AppSpacing.s24,
            ),
            children: [
              Text(
                'What $roleName can do here',
                style: AppText.ui.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(
                'Messages are not shown while previewing.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: AppSpacing.s12),
              for (final bit in bits)
                PermissionRow(
                  label: _permLabel(bit),
                  control: _Answer(allowed: channel.permissions & bit != 0),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The permission's name as the roles editor words it.
String _permLabel(int bit) =>
    Perm.editable.firstWhere((entry) => entry.$1 == bit).$2;

class _Answer extends StatelessWidget {
  const _Answer({required this.allowed});

  final bool allowed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final color = allowed ? tokens.textPrimary : tokens.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s4,
      children: [
        Text(allowed ? 'Yes' : 'No', style: AppText.ui.copyWith(color: color)),
        Icon(
          allowed ? AppIcons.check : AppIcons.notAllowed,
          size: AppSizes.icon16,
          color: color,
        ),
      ],
    );
  }
}
