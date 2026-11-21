// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop video panel, where a video plays on once its message left the
/// screen: a header with the video's title, the player, and whatever the
/// shell docks below it. Beside the chat it is a third pane
/// ([DockedVideoLayout.side]); without room for one it is a strip above the
/// conversation ([DockedVideoLayout.strip]). Width decides which, never the
/// platform (docs/design/desktop-vs-mobile.md, rule 8).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../providers/desktop_video.dart';
import '../providers/desktop_video_player.dart';
import '../providers/embedded_video_player.dart';
import 'desktop_video_view.dart';

enum DockedVideoLayout { side, strip }

/// YouTube's embed rules ask for a viewport of at least 200 by 200.
const double kMinPlayerHeight = 200;

/// The widest a strip's player grows, so a wide conversation keeps its room.
const double kStripPlayerMaxWidth = 640;

const _openOnYoutube = 'Open on YouTube';

/// A strip leaves most of a short window to the conversation it sits above.
double _stripMaxHeight(double windowHeight) =>
    math.max(kMinPlayerHeight, windowHeight * 0.4);

class DockedVideoPanel extends ConsumerWidget {
  const DockedVideoPanel({super.key, required this.layout, this.below});

  /// The box the player's texture fills.
  static const playerKey = Key('docked-video-player');

  final DockedVideoLayout layout;

  /// What fills the side pane under the player, such as the member roster.
  final Widget? below;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = ref.watch(desktopVideoProvider);
    final player = ref.read(desktopVideoProvider.notifier).player;
    if (video == null || !video.docked || player == null) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final body = _PlayerBody(
      key: ValueKey(video.videoId),
      video: video,
      player: player,
      strip: layout == DockedVideoLayout.strip,
    );
    final header = _VideoHeader(
      video: video,
      onClose: ref.read(desktopVideoProvider.notifier).close,
    );
    return Semantics(
      container: true,
      label: 'Video player',
      child: ColoredBox(
        color: tokens.surfaceRaised,
        child: switch (layout) {
          DockedVideoLayout.side => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              body,
              if (below case final below?)
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: tokens.borderSubtle),
                      ),
                    ),
                    child: below,
                  ),
                )
              else
                const Spacer(),
            ],
          ),
          DockedVideoLayout.strip => DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [header, body],
            ),
          ),
        },
      ),
    );
  }
}

class _VideoHeader extends StatelessWidget {
  const _VideoHeader({required this.video, required this.onClose});

  final DesktopVideo video;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final author = video.author;
    // The header bar's height, so the player starts on the line the channel header ends on.
    return Container(
      height: AppSizes.headerBar,
      padding: const EdgeInsets.only(
        left: AppSpacing.s12,
        right: AppSpacing.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    video.title ?? 'YouTube video',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(
                      fontWeight: AppWeights.semi,
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
                if (author != null)
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          AppIconButton(
            icon: AppIcons.externalLink,
            semanticLabel: _openOnYoutube,
            tooltip: _openOnYoutube,
            iconSize: AppSizes.icon16,
            onPressed: () => unawaited(openExternalHttpUrl(video.url)),
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Close player',
            tooltip: 'Close player',
            iconSize: AppSizes.icon16,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The player box, or why it cannot play, for one video.
class _PlayerBody extends StatefulWidget {
  const _PlayerBody({
    super.key,
    required this.video,
    required this.player,
    required this.strip,
  });

  final DesktopVideo video;
  final DesktopVideoPlayer player;
  final bool strip;

  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody> {
  StreamSubscription<VideoPlayerEvent>? _events;
  VideoFailed? _failure;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(_PlayerBody old) {
    super.didUpdateWidget(old);
    if (!identical(old.player, widget.player)) _listen();
  }

  void _listen() {
    unawaited(_events?.cancel());
    _events = widget.player.events.listen((event) {
      if (event is VideoFailed) setState(() => _failure = event);
    });
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    final framed = failure == null
        ? DesktopVideoView(player: widget.player)
        : Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s12),
              child: AppErrorState(
                message: failure.embeddingRefused
                    ? 'This video can only be watched on YouTube.'
                    : 'This video could not be played here.',
                retryLabel: _openOnYoutube,
                onRetry: () => unawaited(openExternalHttpUrl(widget.video.url)),
              ),
            ),
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final stripMax = math.min(
          kStripPlayerMaxWidth,
          _stripMaxHeight(MediaQuery.sizeOf(context).height) * 16 / 9,
        );
        final width = widget.strip
            ? math.min(constraints.maxWidth, stripMax)
            : constraints.maxWidth;
        final height = math.max(width * 9 / 16, kMinPlayerHeight);
        return Center(
          child: SizedBox(
            key: DockedVideoPanel.playerKey,
            width: width,
            height: height,
            child: framed,
          ),
        );
      },
    );
  }
}
