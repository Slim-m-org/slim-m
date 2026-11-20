// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inside of an ordinary link preview card: the linked page's site name,
/// title, author, description and proxied image - or, for a recognized
/// YouTube video, that thumbnail under a click-to-play glyph.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LinkPreview;
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../../../routing/modal_page.dart' show kScrimColor;
import '../../../widgets/text_link.dart';
import '../../video/widgets/desktop_inline_video.dart';
import '../../video/widgets/inline_video_box.dart';
import '../../video/widgets/inline_video_player.dart';
import '../providers/media_preferences.dart';
import 'attachment_reveal.dart';
import 'attachment_view.dart' show AttachmentView, kInlineImageMax;
import 'inline_embed_frame.dart';
import 'link_preview_thumbnail.dart';

class LinkPreviewBody extends StatelessWidget {
  const LinkPreviewBody({
    super.key,
    required this.url,
    required this.preview,
    required this.revealed,
    required this.onReveal,
    required this.playing,
    required this.onPlay,
    this.playingOnDesktop = false,
    this.playingInPanel = false,
  });

  final String url;
  final LinkPreview preview;

  /// Set once the reader taps a held image; see [AttachmentView]'s own
  /// field of the same name and reason.
  final bool revealed;
  final VoidCallback onReveal;

  /// Whether the inline player has replaced a video's thumbnail.
  final bool playing;
  final VoidCallback onPlay;

  /// Whether the desktop's shared player shows this video here.
  final bool playingOnDesktop;

  /// Whether this video is the one playing in the desktop panel.
  final bool playingInPanel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (preview.siteName case final siteName?)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.link, size: 12, color: tokens.textSecondary),
              const SizedBox(width: AppSpacing.s4),
              Flexible(
                child: Text(
                  siteName,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
            ],
          ),
        if (preview.title case final title?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(
                fontWeight: AppWeights.semi,
                color: tokens.textPrimary,
              ),
            ),
          ),
        if (preview.authorName case final authorName?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: _AuthorRow(name: authorName, url: preview.authorUrl),
          ),
        if (preview.description case final description?)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        if (preview.imageToken != null || preview.isPlayableVideo)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s8),
            child: _LinkPreviewMedia(
              url: url,
              preview: preview,
              revealed: revealed,
              onReveal: onReveal,
              playing: playing,
              playingOnDesktop: playingOnDesktop,
              playingInPanel: playingInPanel,
              onPlay: onPlay,
            ),
          ),
      ],
    );
  }
}

/// The linked page's author or publisher - a recognized video's channel
/// today - subordinate to the title, the same caption treatment the
/// site name row above it gets. Tappable to open [url] in the system
/// browser when known; plain text otherwise.
class _AuthorRow extends StatelessWidget {
  const _AuthorRow({required this.name, this.url});

  final String name;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final authorUrl = url;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(AppIcons.account, size: 12, color: tokens.textSecondary),
        const SizedBox(width: AppSpacing.s4),
        Flexible(
          child: Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: authorUrl == null ? tokens.textSecondary : tokens.accent,
            ),
          ),
        ),
      ],
    );
    if (authorUrl == null) return row;
    return TextLink(
      onOpen: () => unawaited(openExternalHttpUrl(authorUrl)),
      child: row,
    );
  }
}

const _youtubeAllow =
    'autoplay; encrypted-media; fullscreen; picture-in-picture';

/// The preview's media area: a static thumbnail for an ordinary link, or,
/// for a recognized video, the same thumbnail under a play glyph (tap calls
/// [onPlay]) that becomes the inline player once [playing] or
/// [playingOnDesktop], or says the video is in the desktop panel while
/// [playingInPanel], where a tap brings it back here. The
/// auto-download reveal gate below applies to the thumbnail exactly as it
/// always has - the click-to-play affordance is a second, separate action on
/// top of it, never a way around it.
class _LinkPreviewMedia extends ConsumerWidget {
  const _LinkPreviewMedia({
    required this.url,
    required this.preview,
    required this.revealed,
    required this.onReveal,
    required this.playing,
    required this.playingOnDesktop,
    required this.playingInPanel,
    required this.onPlay,
  });

  final String url;
  final LinkPreview preview;
  final bool revealed;
  final VoidCallback onReveal;
  final bool playing;
  final bool playingOnDesktop;
  final bool playingInPanel;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (playingOnDesktop) {
      return DesktopInlineVideo(url: url, maxWidth: kInlineImageMax);
    }
    final videoId = preview.videoId;
    if (playing && !kIsWeb && preview.isPlayableVideo && videoId != null) {
      return InlineVideoPlayer(
        url: url,
        videoId: videoId,
        start: preview.videoStart,
        maxWidth: kInlineImageMax,
      );
    }
    if (playing) {
      final embedUrl = preview.embedUrl;
      if (embedUrl == null) return const SizedBox.shrink();
      final frame = ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: buildInlineEmbedFrame(embedUrl, allow: _youtubeAllow),
      );
      if (preview.isPlayableVideo) {
        return InlineVideoBox(maxWidth: kInlineImageMax, child: frame);
      }
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kInlineImageMax),
        child: AspectRatio(aspectRatio: 16 / 9, child: frame),
      );
    }

    final token = preview.imageToken;
    final autoDownload = ref.watch(mediaAutoDownloadControllerProvider);
    if (token != null &&
        autoDownload == MediaAutoDownload.manual &&
        !revealed) {
      return AttachmentRevealTile(
        icon: AppIcons.image,
        line: 'Tap to load preview',
        caption: 'Link preview image',
        maxEdge: kInlineImageMax,
        onReveal: onReveal,
      );
    }

    if (!preview.isPlayableVideo) {
      return token == null
          ? const _LinkPreviewVideoPlaceholder()
          : LinkPreviewThumbnail(token: token, url: url);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPlay,
        child: InlineVideoBox(
          maxWidth: kInlineImageMax,
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              token == null
                  ? const _LinkPreviewVideoPlaceholder()
                  : LinkPreviewThumbnail(token: token, url: url, fill: true),
              Center(
                child: playingInPanel
                    ? const _InPanelBadge()
                    : const _PlayGlyph(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stands in for a video preview with no thumbnail of its own (an og:video
/// page with no og:image) so the play glyph still has something to sit on.
class _LinkPreviewVideoPlaceholder extends StatelessWidget {
  const _LinkPreviewVideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.stripe,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
    );
  }
}

/// The play glyph centred over a video preview's thumbnail, the same shape
/// `attachment_reveal.dart`'s own play badge uses for a held gif's first
/// frame.
class _PlayGlyph extends StatelessWidget {
  const _PlayGlyph();

  /// Opaque white regardless of theme: this sits on an arbitrary decoded
  /// thumbnail, not a themed surface.
  static const _glyphOnDark = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s12),
      decoration: const BoxDecoration(
        color: kScrimColor,
        shape: BoxShape.circle,
      ),
      child: const Icon(
        AppIcons.play,
        size: AppSizes.icon28,
        color: _glyphOnDark,
      ),
    );
  }
}

/// Stands where the play glyph was while the video plays in the desktop
/// panel, so the reader can see which message is on screen beside them; a
/// tap brings the video back into this message.
class _InPanelBadge extends StatelessWidget {
  const _InPanelBadge();

  static const _onScrim = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: kScrimColor,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(AppIcons.play, size: AppSizes.icon16, color: _onScrim),
          const SizedBox(width: AppSpacing.s8),
          Text(
            'Playing in panel',
            style: AppText.caption.copyWith(
              color: _onScrim,
              fontWeight: AppWeights.semi,
            ),
          ),
        ],
      ),
    );
  }
}
