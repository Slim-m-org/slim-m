// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop player in place inside its message, at the size of the
/// thumbnail it replaced: the same box a phone's player fills. Scrolled
/// wholly out of its list's sight, it hands the video on to the panel.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../providers/desktop_video.dart';
import '../providers/desktop_video_player.dart';
import '../providers/embedded_video_player.dart';
import 'desktop_video_view.dart';
import 'docked_video_panel.dart' show kMinPlayerHeight;

class DesktopInlineVideo extends ConsumerStatefulWidget {
  const DesktopInlineVideo({
    super.key,
    required this.url,
    required this.maxWidth,
  });

  /// The pasted link, opened in the browser when the video cannot play here.
  final String url;
  final double maxWidth;

  @override
  ConsumerState<DesktopInlineVideo> createState() => _DesktopInlineVideoState();
}

class _DesktopInlineVideoState extends ConsumerState<DesktopInlineVideo> {
  DesktopVideoPlayer? _player;
  StreamSubscription<VideoPlayerEvent>? _events;
  VideoFailed? _failure;
  ScrollableState? _scrollable;
  bool _checkQueued = false;

  @override
  void initState() {
    super.initState();
    _bind(ref.read(desktopVideoProvider.notifier).player);
  }

  void _bind(DesktopVideoPlayer? player) {
    if (identical(player, _player)) return;
    unawaited(_events?.cancel());
    _player = player;
    _failure = null;
    _events = player?.events.listen((event) {
      if (event is VideoFailed && mounted) setState(() => _failure = event);
      if (event is VideoReady && _failure != null && mounted) {
        setState(() => _failure = null);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    if (identical(scrollable, _scrollable)) return;
    _scrollable?.position.removeListener(_queueCheck);
    _scrollable = scrollable?..position.addListener(_queueCheck);
  }

  /// Checked after the frame the scroll lands in, once layout has placed this box.
  void _queueCheck() {
    if (_checkQueued) return;
    _checkQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkQueued = false;
      if (mounted && !_inSight()) {
        ref.read(desktopVideoProvider.notifier).scrolledAway();
      }
    });
  }

  bool _inSight() {
    final box = context.findRenderObject();
    final viewport = _scrollable?.context.findRenderObject();
    if (box is! RenderBox || viewport is! RenderBox) return true;
    if (!box.attached || !viewport.attached) return true;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final sight = viewport.localToGlobal(Offset.zero) & viewport.size;
    return rect.overlaps(sight);
  }

  @override
  void dispose() {
    _scrollable?.position.removeListener(_queueCheck);
    unawaited(_events?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopVideoProvider.select((v) => v?.videoId));
    _bind(ref.read(desktopVideoProvider.notifier).player);
    final player = _player;
    final failure = _failure;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, widget.maxWidth);
        final height = math.max(width * 9 / 16, kMinPlayerHeight);
        return SizedBox(
          width: width,
          height: height,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: failure == null && player != null
                ? DesktopVideoView(player: player)
                : Center(
                    child: AppErrorState(
                      message: failure?.embeddingRefused ?? false
                          ? 'This video can only be watched on YouTube.'
                          : 'This video could not be played here.',
                      retryLabel: 'Open on YouTube',
                      onRetry: () => unawaited(openExternalHttpUrl(widget.url)),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
