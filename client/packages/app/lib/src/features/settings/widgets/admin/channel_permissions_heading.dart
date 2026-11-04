// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Channel permissions pane heading beside a nav: plain on the channel
/// list, a breadcrumb with a back arrow once a channel is open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../providers/channel_permissions_selection.dart';
import '../settings_panes_chrome.dart';

class ChannelPermissionsHeading extends ConsumerWidget {
  const ChannelPermissionsHeading({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel = ref.watch(channelPermissionsSelectionProvider);
    if (channel == null) {
      return SettingsPaneHeading('Channel permissions', onClose: onClose);
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    void back() =>
        ref.read(channelPermissionsSelectionProvider.notifier).state = null;
    return SizedBox(
      height: AppSizes.controlLg,
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          AppIconButton(
            icon: AppIcons.back,
            semanticLabel: 'Back to channels',
            tooltip: 'Back to channels',
            iconSize: AppSizes.icon16,
            onPressed: back,
          ),
          Expanded(
            child: Row(
              spacing: AppSpacing.s8,
              children: [
                Flexible(
                  child: GestureDetector(
                    onTap: back,
                    child: Text(
                      'Channel permissions',
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(color: tokens.textSecondary),
                    ),
                  ),
                ),
                Text(
                  '/',
                  style: AppText.heading.copyWith(color: tokens.textSecondary),
                ),
                Flexible(
                  child: Semantics(
                    header: true,
                    child: Text(
                      channel.name,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.heading.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (onClose != null)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Close settings',
              tooltip: 'Close settings',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
