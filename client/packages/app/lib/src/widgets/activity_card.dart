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
const _boxedArtSide = AppSpacing.s40;
const _artDecodeWidth = 192;

class ActivityCard extends ConsumerWidget {
  const ActivityCard({super.key, required this.activity, this.boxed = false});

  final api.PresenceActivity activity;

  /// The profile card's version: a sunken box, a smaller tile and a label heading.
  final bool boxed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final subtitle = activity.subtitle;
    final row = Row(
      children: [
        _Cover(
          activity: activity,
          side: boxed ? _boxedArtSide : _artSide,
          tile: boxed,
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
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
          ),
        ),
      ],
    );
    if (!boxed) return row;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s12),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: row,
    );
  }
}

class _Cover extends ConsumerWidget {
  const _Cover({
    required this.activity,
    required this.side,
    required this.tile,
  });

  final api.PresenceActivity activity;
  final double side;

  /// Sits on a sunken box, so the placeholder lifts to the raised surface.
  final bool tile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final url = activity.artUrl;
    final placeholder = ColoredBox(
      color: tile ? tokens.surfaceRaised : tokens.surfaceSunken,
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
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
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
