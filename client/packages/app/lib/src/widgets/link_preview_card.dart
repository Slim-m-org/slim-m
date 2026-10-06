// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card a pasted URL unfurls into below a message: the linked page's
/// site name, title, author, description and proxied image, one card per
/// link - or, for a link recognized as a playable video (YouTube today), the
/// same card with a click-to-play affordance over the thumbnail instead of a
/// static image and, when known, the video's channel as the author line.
///
/// Privacy is the point of the click-to-play affordance: nothing from the
/// video provider loads on render, only when the reader taps. On web that
/// tap swaps the thumbnail for an inline `youtube-nocookie.com` iframe
/// (`youtube_inline_player.dart`, loaded only then). Every other platform
/// has no iframe host off the web engine and this app carries no webview
/// dependency to fake one, so a tap there opens [url] in the system browser
/// instead - the same [_open] path an ordinary link preview already uses.
///
/// A missing or failed preview renders nothing - never an error surface -
/// since a link that fails to unfurl is not something the reader did wrong,
/// and the link itself already rendered as a tappable [InlineLink] in the
/// body above this.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LinkPreview;
import 'package:slimm_design_system/design_system.dart';

import '../external_link.dart';
import '../providers/attachment_preview_quality.dart';
import '../providers/link_preview.dart';
import '../providers/media_preferences.dart';
import '../routing/modal_page.dart' show kScrimColor;
import 'attachment_reveal.dart';
import 'attachment_view.dart' show kInlineImageMax;
import 'image_decode.dart';
import 'text_link.dart';
import 'youtube_inline_player.dart';

/// One card per URL, below a message's own text. Callers cap [urls] before
/// handing them here; this renders exactly what it is given.
class LinkPreviewList extends StatelessWidget {
  const LinkPreviewList({super.key, required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final url in urls)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: LinkPreviewCard(url: url),
          ),
      ],
    );
  }
}

class LinkPreviewCard extends ConsumerStatefulWidget {
  const LinkPreviewCard({super.key, required this.url});

  final String url;

  @override
  ConsumerState<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends ConsumerState<LinkPreviewCard> {
  /// Set once the reader taps a held image; see [AttachmentView]'s own
  /// field of the same name and reason.
  bool _revealed = false;

  /// Set once the reader taps a playable video's card, on web only - see
  /// [_handlePlayTap]. Always false on every other platform, since there the
  /// tap opens the system browser instead of swapping in an inline player.
  bool _playing = false;

  Future<void> _open() async => openExternalHttpUrl(widget.url);

  /// The click-to-play action for a recognized video: on web, swap the
  /// thumbnail for an inline `youtube-nocookie.com` iframe with nothing
  /// fetched from the provider until now; everywhere else, Flutter has no
  /// iframe host, so this opens [url] in the system browser exactly like an
  /// ordinary link preview's tap already does.
  void _handlePlayTap() {
    if (kIsWeb) {
      setState(() => _playing = true);
    } else {
      unawaited(_open());
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(linkPreviewProvider(widget.url)).valueOrNull;
    if (preview == null) return const SizedBox.shrink();
    final hasText =
        preview.siteName != null ||
        preview.title != null ||
        preview.description != null ||
        preview.authorName != null;
    if (!hasText && preview.imageToken == null && !preview.isPlayableVideo) {
      return const SizedBox.shrink();
    }
    final onCardTap = preview.isPlayableVideo ? _handlePlayTap : _open;

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: preview.isPlayableVideo
          ? 'Play video preview for ${preview.title ?? widget.url}'
          : 'Open link preview for ${preview.title ?? widget.url}',
      onTap: onCardTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onCardTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: tokens.borderSubtle),
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              padding: const EdgeInsets.all(AppSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (preview.siteName case final siteName?)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          AppIcons.link,
                          size: 12,
                          color: tokens.textSecondary,
                        ),
                        const SizedBox(width: AppSpacing.s4),
                        Flexible(
                          child: Text(
                            siteName,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              color: tokens.textSecondary,
                            ),
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
                      child: _AuthorRow(
                        name: authorName,
                        url: preview.authorUrl,
                      ),
                    ),
                  if (preview.description case final description?)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.s4),
                      child: Text(
                        description,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                    ),
                  if (preview.imageToken != null || preview.isPlayableVideo)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.s8),
                      child: _LinkPreviewMedia(
                        preview: preview,
                        revealed: _revealed,
                        onReveal: () => setState(() => _revealed = true),
                        playing: _playing,
                        onPlay: _handlePlayTap,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
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

/// The preview's media area: a static thumbnail for an ordinary link, or,
/// for a recognized video, the same thumbnail under a play glyph (tap calls
/// [onPlay]) that becomes an inline web player once [playing]. The
/// auto-download reveal gate below applies to the thumbnail exactly as it
/// always has - the click-to-play affordance is a second, separate action on
/// top of it, never a way around it.
class _LinkPreviewMedia extends ConsumerWidget {
  const _LinkPreviewMedia({
    required this.preview,
    required this.revealed,
    required this.onReveal,
    required this.playing,
    required this.onPlay,
  });

  final LinkPreview preview;
  final bool revealed;
  final VoidCallback onReveal;
  final bool playing;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (playing) {
      final embedUrl = preview.embedUrl;
      if (embedUrl == null) return const SizedBox.shrink();
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kInlineImageMax),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: buildYoutubeInlinePlayer(embedUrl),
          ),
        ),
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

    final thumbnail = token == null
        ? const _LinkPreviewVideoPlaceholder()
        : _LinkPreviewThumbnail(token: token);
    if (!preview.isPlayableVideo) return thumbnail;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onPlay,
        child: Stack(
          alignment: Alignment.center,
          children: [thumbnail, const _PlayGlyph()],
        ),
      ),
    );
  }
}

/// The decoded thumbnail image, honoring the same preview-quality setting
/// [AttachmentView] applies to an inline attachment image.
class _LinkPreviewThumbnail extends ConsumerWidget {
  const _LinkPreviewThumbnail({required this.token});

  final String token;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previewScale = ref
        .watch(attachmentPreviewQualityControllerProvider)
        .decodeScale;
    final decodeWidth = decodeEdge(
      context,
      kInlineImageMax,
      scale: previewScale,
    );
    final bytesAsync = ref.watch(linkPreviewImageBytesProvider(token));
    final bytes = bytesAsync.valueOrNull;
    if (bytes == null) return const SizedBox.shrink();

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: kInlineImageMax,
          maxHeight: kInlineImageMax,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            cacheWidth: decodeWidth,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kInlineImageMax),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.stripe,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
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
