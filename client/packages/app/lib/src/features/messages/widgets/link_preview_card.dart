// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card a pasted URL unfurls into below a message, one card per link:
/// the linked page's site name, title, author, description and proxied image
/// ([LinkPreviewBody]), a recognized YouTube video's thumbnail under a
/// click-to-play glyph, or a Spotify item's cover, name and Play button
/// ([SpotifyPreviewBody]).
///
/// Privacy is the point of click-to-play: nothing from the provider loads on
/// render, only when the reader taps. Where a tapped video plays is
/// `videoHostKindProvider`'s answer: in place (the web build's iframe, a
/// phone's webview), in the desktop panel beside the chat, or in the system
/// browser where neither exists. A Spotify item plays inline on web and
/// opens the Spotify app or site everywhere else.
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
import '../../video/providers/docked_video.dart';
import '../../video/providers/video_host_capability.dart';
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

  /// Set once the reader taps a video that plays in place, or a Spotify
  /// item's Play on web - see [_handlePlayTap].
  bool _playing = false;

  bool _hovered = false;
  bool _removeFocused = false;

  bool get _hasMouse => RendererBinding.instance.mouseTracker.mouseIsConnected;

  /// A playing embed is an iframe the pointer's hover never reaches, so its
  /// X stays shown rather than vanishing the moment the reader moves onto it.
  bool get _xShown => _hovered || _removeFocused || !_hasMouse || _playing;

  Future<void> _open() async => openExternalHttpUrl(widget.url);

  /// The click-to-play action for a recognized video, with nothing fetched
  /// from the provider until now: the thumbnail becomes the player in place,
  /// the video moves to the desktop panel, or [url] opens in the browser.
  void _handlePlayTap(LinkPreview preview) {
    final host =
        ref.read(videoHostKindProvider).valueOrNull ?? VideoHostKind.external;
    switch (host) {
      case VideoHostKind.inline:
        setState(() => _playing = true);
      case VideoHostKind.docked:
        ref.read(dockedVideoProvider.notifier).open(widget.url, preview);
      case VideoHostKind.external:
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
    final inPanel = ref.watch(
      dockedVideoProvider.select((v) => v?.url == widget.url),
    );
    // Probed ahead of the tap, so the tap already knows where the video plays.
    if (preview.isPlayableVideo) ref.watch(videoHostKindProvider);
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
    void play() => _handlePlayTap(preview);
    final VoidCallback onCardTap = spotify != null
        ? () => _openSpotify(spotify)
        : inPanel
        ? () {}
        : preview.isPlayableVideo
        ? play
        : _open;

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: kCardBottomGap),
      child: Semantics(
        button: true,
        label: spotify != null
            ? _spotifyLabel(preview, spotify)
            : inPanel
            ? 'Playing in panel: ${preview.title ?? widget.url}'
            : preview.isPlayableVideo
            ? 'Play video preview for ${preview.title ?? widget.url}'
            : 'Open link preview for ${preview.title ?? widget.url}',
        onTap: onCardTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            // A playing player takes its own taps, pause and seek included.
            onTap: _playing ? null : onCardTap,
            child: SelectionContainer.disabled(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: spotify != null
                      ? kSpotifyCardMax
                      : kMessageColumnMax,
                ),
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
                              playingInPanel: inPanel,
                              onPlay: play,
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
                            opacity: _xShown ? 1 : 0,
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
