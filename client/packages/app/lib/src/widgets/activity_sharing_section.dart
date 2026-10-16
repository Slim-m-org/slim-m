// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every rich-presence switch, and what is being shared right now, in one
/// place (decision 0044).
///
/// Each source is off by default and absent on a platform that has none
/// rather than shown dead. It is a card of the Profile pane because it decides
/// what your profile card and member row say about you.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/activity_feeds.dart';
import '../providers/activity_sharing_settings.dart';
import '../spotify/spotify_link.dart';
import '../spotify/spotify_link_status.dart';
import 'activity_card.dart';
import 'activity_game_list.dart';
import 'settings_section_header.dart';
import 'settings_toggle_row.dart';
import 'spotify_link_row.dart';

class ActivitySharingSection extends ConsumerWidget {
  const ActivitySharingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feeds = ref.watch(availableActivityFeedsProvider);
    if (feeds.isEmpty) return const SizedBox.shrink();
    final spotifyShown =
        ref.watch(spotifyLinkStatusProvider) is! SpotifyUnlinked;
    return SettingsSectionCard(
      flush: true,
      title: 'Activity',
      description:
          'Shown to people who see your status, never when appearing offline.',
      children: [
        const _SharingNow(),
        for (final feed in feeds) ...[
          SettingsToggleRow(
            label: feed.label,
            description: feed.description,
            value: ref.watch(feed.enabled),
            onChanged: (value) =>
                ref.read(feed.enabled.notifier).setEnabled(value),
            semanticLabel: feed.label,
          ),
          if (feed.enabled == shareSpotifyProvider && spotifyShown)
            const SpotifyLinkRow(),
          if (feed.enabled == shareGameProvider) const ActivityGameList(),
        ],
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
              ActivityCard(activity: shared),
            ],
          ],
        ),
      ),
    );
  }
}
