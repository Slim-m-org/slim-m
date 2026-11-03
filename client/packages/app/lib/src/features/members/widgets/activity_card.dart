// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One activity as a small card: cover art (or a placeholder), who is
/// reporting it, the title and the artist (decisions 0044 and 0056).
///
/// The profile card and the Settings preview draw the same thing, so what a
/// person previews is what others read. The cover is fetched by this client
/// from Spotify's CDN only; [isAllowedArtUrl] is checked again here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/presence_activity.dart';

/// How a cover address becomes pixels. Overridden in tests so no network is
/// touched.
final activityArtImageProvider = Provider<ImageProvider Function(String url)>(
  (ref) =>
      (url) => ResizeImage(
        NetworkImage(url),
        width: _artDecodeWidth,
        policy: ResizeImagePolicy.fit,
      ),
);

const _artSide = AppSpacing.s48;
const _boxedArtSide = AppSpacing.s64;
const _artDecodeWidth = 192;

class ActivityCard extends ConsumerWidget {
  const ActivityCard({super.key, required this.activity, this.boxed = false});

  final api.PresenceActivity activity;

  /// The profile card's version: a sunken box with a flush cover and the Spotify mark.
  final bool boxed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final subtitle = activity.subtitle;
    final showsSpotifyMark =
        boxed && activity.source == BrandService.spotify.label;
    final texts = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!showsSpotifyMark)
          Text(
            boxed
                ? activityHeading(activity).toUpperCase()
                : activityHeading(activity),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (boxed ? AppText.label : AppText.caption).copyWith(
              color: tokens.textSecondary,
            ),
          ),
        Text(
          activity.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.ui.copyWith(
            color: tokens.textPrimary,
            fontWeight: boxed ? AppWeights.medium : null,
          ),
        ),
        if (subtitle != null)
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
    if (!boxed) {
      return Row(
        children: [
          _Cover(activity: activity, side: _artSide),
          const SizedBox(width: AppSpacing.s12),
          Expanded(child: texts),
        ],
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Stack(
        children: [
          Row(
            children: [
              _Cover(activity: activity, side: _boxedArtSide, flush: true),
              const SizedBox(width: AppSpacing.s12),
              Expanded(child: texts),
              if (showsSpotifyMark) const SizedBox(width: AppSpacing.s32),
            ],
          ),
          if (showsSpotifyMark)
            const Positioned(
              top: AppSpacing.s8,
              right: AppSpacing.s8,
              child: BrandLogo(
                BrandService.spotify,
                key: Key('activity-spotify-mark'),
                size: AppSizes.icon20,
              ),
            ),
        ],
      ),
    );
  }
}

class _Cover extends ConsumerWidget {
  const _Cover({
    required this.activity,
    required this.side,
    this.flush = false,
  });

  final api.PresenceActivity activity;
  final double side;

  /// Fills the card's left edge, so the card clips it and it draws no border.
  final bool flush;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final url = activity.artUrl;
    final placeholder = ColoredBox(
      color: flush ? tokens.surfaceRaised : tokens.surfaceSunken,
      child: Center(
        child: Icon(
          activityIcon(activity.kind),
          size: AppSizes.icon20,
          color: tokens.textSecondary,
        ),
      ),
    );
    return ExcludeSemantics(
      child: Container(
        key: const Key('activity-cover'),
        width: side,
        height: side,
        clipBehavior: flush ? Clip.none : Clip.antiAlias,
        decoration: flush
            ? null
            : BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.control),
                border: Border.all(color: tokens.borderSubtle),
              ),
        child: url == null
            ? placeholder
            : Image(
                image: ref.watch(activityArtImageProvider)(url),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) =>
                    progress == null ? child : placeholder,
              ),
      ),
    );
  }
}
