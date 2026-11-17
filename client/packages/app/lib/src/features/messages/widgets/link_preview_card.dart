// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card a pasted URL unfurls into below a message, one card per link:
/// the linked page's site name, title, author, description and proxied image
/// ([LinkPreviewBody]), a recognized YouTube video's thumbnail under a
/// click-to-play glyph, or a Spotify item's cover, name and Play button
/// ([SpotifyPreviewBody]).
///
/// Privacy is the point of click-to-play: nothing from the provider loads on
/// render, only when the reader taps. On web that tap swaps in the
/// provider's own iframe (`inline_embed_frame.dart`, loaded only then).
/// Every other platform has no iframe host off the web engine and this app
/// carries no webview dependency to fake one, so a tap there opens a video
/// in the system browser and a Spotify item in the Spotify app or site.
///
/// A missing or failed preview renders nothing - never an error surface -
/// since a link that fails to unfurl is not something the reader did wrong,
/// and the link itself already rendered as a tappable [InlineLink] in the
/// body above this.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LinkPreview, SpotifyEntity;
import 'package:slimm_data/data.dart' show Message;
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../providers/link_preview.dart';
import '../providers/media_preferences.dart';
import '../providers/message_actions.dart';
import '../../channels/providers/channel_permissions.dart';
import '../../../providers/providers.dart' show sessionProvider;
import 'card_spacing.dart';
import 'link_preview_body.dart';
import 'spotify_preview_body.dart';

/// One card per URL, below a message's own text. Callers cap [urls] before
/// handing them here; this renders exactly what it is given. Whoever may
/// remove [message]'s previews gets an X on each card, which removes them all.
class LinkPreviewList extends ConsumerWidget {
  const LinkPreviewList({super.key, required this.urls, required this.message});

  final List<String> urls;
  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden =
        ref.watch(linkPreviewDisplayControllerProvider) ==
        LinkPreviewDisplay.hide;
    if (urls.isEmpty || hidden) return const SizedBox.shrink();
    final canRemove = canRemoveLinkPreviews(
      message,
      ref.watch(sessionProvider.select((s) => s.tokens?.userId)),
      ref.watch(myChannelPermissionsProvider(message.channelId)),
    );
    final failure = ref.watch(linkPreviewRemovalErrorProvider(message.id));
    void remove() => unawaited(removeLinkPreviews(ref, message));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final url in urls)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: LinkPreviewCard(
              url: url,
              onRemove: canRemove ? remove : null,
              removeLabel: urls.length > 1
                  ? 'Remove all link previews'
                  : 'Remove link preview',
            ),
          ),
        if (failure != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: AppErrorState(
              message: failure,
              onRetry: remove,
              onDismiss: () =>
                  ref
                          .read(
                            linkPreviewRemovalErrorProvider(
                              message.id,
                            ).notifier,
                          )
                          .state =
                      null,
            ),
          ),
      ],
    );
  }
}

class LinkPreviewCard extends ConsumerStatefulWidget {
  const LinkPreviewCard({
    super.key,
    required this.url,
    this.onRemove,
    this.removeLabel = 'Remove link preview',
  });

  final String url;

  /// An X over the card, faded in while the pointer or keyboard focus is on
  /// it and always shown where there is no pointer to hover with. It stays
  /// mounted so it can be tabbed to and announced. Null for a reader who may
  /// not remove it.
  final VoidCallback? onRemove;

  /// What the X is called, which says how much it removes.
  final String removeLabel;

  @override
  ConsumerState<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends ConsumerState<LinkPreviewCard> {
  /// Set once the reader taps a held image; see [AttachmentView]'s own
  /// field of the same name and reason.
  bool _revealed = false;

  /// Set once the reader taps a video's card or a Spotify item's Play, on
  /// web only - see [_handlePlayTap]. Always false on every other platform,
  /// since there the tap opens another app instead of an inline player.
  bool _playing = false;

  bool _hovered = false;
  bool _removeFocused = false;

  bool get _hasMouse => RendererBinding.instance.mouseTracker.mouseIsConnected;

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

  void _openSpotify(SpotifyEntity item) =>
      unawaited(ref.read(spotifyItemOpenerProvider)(item));

  /// Spotify's own player inline on web; the Spotify app or site elsewhere.
  void _playSpotify(SpotifyEntity item) {
    if (kIsWeb) {
      setState(() => _playing = true);
    } else {
      _openSpotify(item);
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
    final spotify = preview.spotify;
    if (!hasText &&
        preview.imageToken == null &&
        !preview.isPlayableVideo &&
        spotify == null) {
      return const SizedBox.shrink();
    }
    final VoidCallback onCardTap = spotify != null
        ? () => _openSpotify(spotify)
        : preview.isPlayableVideo
        ? _handlePlayTap
        : _open;

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: kCardBottomGap),
      child: Semantics(
        button: true,
        label: spotify != null
            ? _spotifyLabel(preview, spotify)
            : preview.isPlayableVideo
            ? 'Play video preview for ${preview.title ?? widget.url}'
            : 'Open link preview for ${preview.title ?? widget.url}',
        onTap: onCardTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: onCardTap,
            child: SelectionContainer.disabled(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: tokens.borderSubtle),
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      padding: EdgeInsets.fromLTRB(
                        AppSpacing.s8,
                        AppSpacing.s8,
                        widget.onRemove == null
                            ? AppSpacing.s8
                            : AppSizes.controlSm,
                        AppSpacing.s8,
                      ),
                      child: spotify != null
                          ? SpotifyPreviewBody(
                              url: widget.url,
                              preview: preview,
                              item: spotify,
                              revealed: _revealed,
                              onReveal: () => setState(() => _revealed = true),
                              playing: _playing,
                              onPlay: () => _playSpotify(spotify),
                            )
                          : LinkPreviewBody(
                              url: widget.url,
                              preview: preview,
                              revealed: _revealed,
                              onReveal: () => setState(() => _revealed = true),
                              playing: _playing,
                              onPlay: _handlePlayTap,
                            ),
                    ),
                    if (widget.onRemove != null)
                      Positioned(
                        top: AppSpacing.s4,
                        right: AppSpacing.s4,
                        child: Focus(
                          canRequestFocus: false,
                          onFocusChange: (focused) =>
                              setState(() => _removeFocused = focused),
                          child: AnimatedOpacity(
                            opacity: _hovered || _removeFocused || !_hasMouse
                                ? 1
                                : 0,
                            duration: AppMotion.fast,
                            alwaysIncludeSemantics: true,
                            child: AppIconButton(
                              icon: AppIcons.dismiss,
                              semanticLabel: widget.removeLabel,
                              tooltip: widget.removeLabel,
                              size: AppIconButtonSize.sm,
                              iconSize: AppSizes.icon16,
                              onPressed: widget.onRemove,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a screen reader hears for a Spotify card: the whole title and
/// summary line, which the card may cut short on screen.
String _spotifyLabel(LinkPreview preview, SpotifyEntity item) {
  final title = spotifyItemName(preview, item);
  final subtitle = spotifySubtitle(item.kind, preview.description);
  return [
    'Open $title on Spotify',
    if (subtitle.isNotEmpty) subtitle,
  ].join('. ');
}
