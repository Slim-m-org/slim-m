// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every rich-presence switch, and what is being shared right now, in one
/// place (decision 0044).
///
/// Each source is off by default and absent on a platform that has none
/// rather than shown dead. It is a card of the Profile pane because it decides
/// what your profile card and member row say about you.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/activity_feeds.dart';
import '../../../spotify/spotify_link.dart';
import '../../../spotify/spotify_link_status.dart';
import '../../settings/providers/linked_accounts.dart';
import '../../settings/providers/steam_connection.dart';
import 'activity_card.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../settings/widgets/settings_toggle_row.dart';

class ActivitySharingSection extends ConsumerWidget {
  const ActivitySharingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spotifyLinked =
        ref.watch(spotifyLinkStatusProvider) is SpotifyConnected;
    final feeds = [
      for (final feed in ref.watch(availableActivityFeedsProvider))
        if (feed.enabled != shareSpotifyProvider || spotifyLinked) feed,
    ];
    final steam = ref
        .watch(myLinkedAccountsProvider)
        .valueOrNull
        ?.where((link) => link.isSteam)
        .firstOrNull;
    if (feeds.isEmpty && steam == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsSectionCard(
          title: 'Activity',
          description:
              'Shown to people who see your status, never when appearing offline.',
          topGap: kDenseSectionTopGap,
          children: [_SharingNow()],
        ),
        SettingsSectionCard(
          topGap: AppSpacing.s12,
          children: [
            for (final feed in feeds) ...[
              SettingsToggleRow(
                label: feed.label,
                description: feed.description,
                value: ref.watch(feed.enabled),
                onChanged: (value) =>
                    ref.read(feed.enabled.notifier).setEnabled(value),
                semanticLabel: feed.label,
              ),
            ],
            if (steam != null) _ShareGameRow(steam: steam),
          ],
        ),
      ],
    );
  }
}

/// Steam's switch lives on the server, so its failures show here beside it.
class _ShareGameRow extends ConsumerWidget {
  const _ShareGameRow({required this.steam});

  final api.LinkedAccount steam;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chosen = ref.watch(steamConnectionProvider.select((c) => c.sharing));
    final error = ref.watch(steamConnectionProvider.select((c) => c.error));
    final controller = ref.read(steamConnectionProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsToggleRow(
          label: "Share what I'm playing",
          description: 'Shows your Steam game to people who see your status.',
          value: chosen ?? steam.shareActivity,
          onChanged: (value) => unawaited(controller.setSharing(value)),
          semanticLabel: "Share what I'm playing",
        ),
        if (error != null)
          SettingsCardBlock(
            children: [
              AppErrorState(message: error, onDismiss: controller.dismissError),
            ],
          ),
      ],
    );
  }
}

class _SharingNow extends ConsumerWidget {
  const _SharingNow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shared = ref.watch(sharedActivityProvider);
    final via = ref.watch(sharedFeedProvider)?.via;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final secondary = AppText.caption.copyWith(color: tokens.textSecondary);
    return ColoredBox(
      color: tokens.surfaceBase,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 28),
              child: Row(
                children: [
                  Expanded(child: Text('Sharing right now', style: secondary)),
                  Text(
                    shared == null ? 'Nothing' : 'From $via',
                    style: secondary,
                  ),
                ],
              ),
            ),
            if (shared != null) ...[
              const SizedBox(height: AppSpacing.s8),
              ActivityCard(activity: shared, boxed: true),
            ],
          ],
        ),
      ),
    );
  }
}
