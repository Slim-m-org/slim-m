// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inside of a Spotify item's link preview card: Spotify's mark, the
/// cover at its own shape, the item's name and summary line, and a Play on
/// Spotify button.
///
/// Spotify's brand rules shape it (decision 0123): the mark is drawn in one
/// colour, since the green one belongs on pure black or white only, and
/// nothing is drawn over the cover, which is never cropped. On web Play
/// swaps the row for Spotify's own embed, unaltered; elsewhere it opens the
/// item in the Spotify app or the browser.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart'
    show LinkPreview, SpotifyEntity, SpotifyKind;
import 'package:slimm_design_system/design_system.dart';

import '../providers/media_preferences.dart';
import 'inline_embed_frame.dart';
import 'link_preview_thumbnail.dart';

/// Spotify's own embed snippet asks for exactly these.
const _embedAllow =
    'autoplay; clipboard-write; encrypted-media; fullscreen; picture-in-picture';

/// The cover's height; its width follows the image, up to a 16:9 episode
/// cover's, or square on a phone so the text keeps its room.
const double _artHeight = AppSpacing.s64 + AppSpacing.s16;
const double _artWidestAspect = 16 / 9;

/// Spotify's monochrome mark is pure white or pure black, never a tinted theme text colour.
const _markOnDark = Color(0xFFFFFFFF);
const _markOnLight = Color(0xFF000000);

// Spotify's design guidelines: cover art corners are 4 px on small screens, 8 px above.
const double _artRadiusCompact = 4;
const double _artRadius = 8;

class SpotifyPreviewBody extends ConsumerWidget {
  const SpotifyPreviewBody({
    super.key,
    required this.url,
    required this.preview,
    required this.item,
    required this.revealed,
    required this.onReveal,
    required this.playing,
    required this.onPlay,
  });

  final String url;
  final LinkPreview preview;
  final SpotifyEntity item;

  /// Set once the reader taps a cover held back by manual auto-download.
  final bool revealed;
  final VoidCallback onReveal;

  /// Whether Spotify's embed has replaced the row, on web only.
  final bool playing;
  final VoidCallback onPlay;

  static const markKey = ValueKey('spotify-preview-mark');
  static const artKey = ValueKey('spotify-preview-art');
  static const playKey = ValueKey('spotify-preview-play');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandLogo(
              BrandService.spotify,
              key: markKey,
              size: AppSizes.icon24,
              monochrome: Theme.of(context).brightness == Brightness.dark
                  ? _markOnDark
                  : _markOnLight,
            ),
            const SizedBox(width: AppSpacing.s8),
            Text(
              BrandService.spotify.label,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s8),
        if (playing) _embed() else _details(context, ref, tokens),
      ],
    );
  }

  Widget _embed() {
    return SizedBox(
      width: double.infinity,
      height: item.embedHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: buildInlineEmbedFrame(item.embedUrl, allow: _embedAllow),
      ),
    );
  }

  Widget _details(BuildContext context, WidgetRef ref, AppTokens tokens) {
    final title = preview.title ?? BrandService.spotify.label;
    final subtitle = spotifySubtitle(item.kind, preview.description);
    final duration = preview.durationMs;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (preview.imageToken case final token?)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s12),
            child: KeyedSubtree(key: artKey, child: _art(context, ref, token)),
          ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(
                  fontWeight: AppWeights.semi,
                  color: tokens.textPrimary,
                ),
              ),
              if (subtitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s4),
                  child: Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(height: AppSpacing.s8),
              Wrap(
                spacing: AppSpacing.s8,
                runSpacing: AppSpacing.s4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  AppButton(
                    key: playKey,
                    label: 'Play on Spotify',
                    icon: AppIcons.play,
                    size: AppButtonSize.sm,
                    semanticLabel: 'Play $title on Spotify',
                    onPressed: onPlay,
                  ),
                  if (duration != null && duration > 0)
                    Text(
                      formatSpotifyDuration(duration),
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _art(BuildContext context, WidgetRef ref, String token) {
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final radius = compact ? _artRadiusCompact : _artRadius;
    final widest = compact ? _artHeight : _artHeight * _artWidestAspect;
    final held =
        ref.watch(mediaAutoDownloadControllerProvider) ==
            MediaAutoDownload.manual &&
        !revealed;
    if (held) {
      return _HeldArt(radius: radius, onReveal: onReveal);
    }
    return LinkPreviewThumbnail(
      token: token,
      url: url,
      bounds: Size(widest, _artHeight),
      radius: radius,
    );
  }
}

/// The summary line under the title. A playlist's description is free text,
/// so it says what it is first.
String spotifySubtitle(SpotifyKind kind, String? description) {
  final summary = description?.trim() ?? '';
  if (kind != SpotifyKind.playlist) return summary;
  return summary.isEmpty ? 'Playlist' : 'Playlist · $summary';
}

/// `5:36` or `2:50:35`.
String formatSpotifyDuration(int milliseconds) {
  final total = milliseconds ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  if (hours == 0) return '$minutes:$seconds';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
}

/// The cover's place while manual auto-download holds it back.
class _HeldArt extends StatelessWidget {
  const _HeldArt({required this.radius, required this.onReveal});

  final double radius;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      container: true,
      label: 'Load the cover',
      onTap: onReveal,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onReveal,
          child: SizedBox.square(
            dimension: _artHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceSunken,
                borderRadius: BorderRadius.circular(radius),
              ),
              child: Icon(
                AppIcons.image,
                size: AppSizes.icon20,
                color: tokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
