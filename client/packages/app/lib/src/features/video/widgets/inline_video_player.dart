// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A YouTube video playing in place inside its message, on a phone, at the
/// size of the thumbnail it replaced. YouTube's own fullscreen button takes
/// it fullscreen, the one time a portrait-locked phone may turn (0058).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../external_link.dart';
import '../../../providers/phone_landscape.dart';
import '../../../widgets/system_bars.dart';
import '../providers/embedded_video_player.dart';
import '../providers/inline_video_player.dart';
import '../providers/video_playback_coordinator.dart';
import 'docked_video_panel.dart' show kMinPlayerHeight;

class InlineVideoPlayer extends ConsumerStatefulWidget {
  const InlineVideoPlayer({
    super.key,
    required this.url,
    required this.videoId,
    required this.start,
    required this.maxWidth,
  });

  /// The pasted link, opened in the browser when the video cannot play here.
  final String url;
  final String videoId;
  final Duration start;
  final double maxWidth;

  @override
  ConsumerState<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends ConsumerState<InlineVideoPlayer> {
  late final InlineVideoHandle _handle;
  late final VideoPlaybackCoordinator _coordinator;
  StreamSubscription<VideoPlayerEvent>? _events;
  VideoFailed? _failure;
  NavigatorState? _fullscreenNavigator;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _coordinator = ref.read(videoPlaybackCoordinatorProvider);
    _handle = ref.read(inlineVideoFactoryProvider)(
      onShowFullscreen: _showFullscreen,
      onHideFullscreen: _hideFullscreen,
    );
    final player = _handle.player;
    _coordinator.attach(player);
    _events = player.events.listen((event) {
      if (event is VideoFailed && mounted) setState(() => _failure = event);
    });
    unawaited(player.load(widget.videoId, start: widget.start));
  }

  void _showFullscreen(Widget view, void Function() onExit) {
    if (_fullscreen) return;
    _fullscreen = true;
    final navigator = _fullscreenNavigator = Navigator.of(
      context,
      rootNavigator: true,
    );
    unawaited(
      navigator
          .push(
            PageRouteBuilder<void>(
              opaque: true,
              pageBuilder: (_, _, _) => _VideoFullscreen(view: view),
            ),
          )
          .then((_) {
            if (_fullscreen) {
              _fullscreen = false;
              onExit();
            }
          }),
    );
  }

  void _hideFullscreen() {
    if (!_fullscreen) return;
    _fullscreen = false;
    _fullscreenNavigator?.pop();
  }

  @override
  void dispose() {
    if (_fullscreen) {
      _fullscreen = false;
      final navigator = _fullscreenNavigator;
      // The tree is locked while this disposes, so the route leaves after the frame.
      SchedulerBinding.instance.addPostFrameCallback((_) => navigator?.pop());
    }
    unawaited(_events?.cancel());
    _coordinator.detach(_handle.player);
    unawaited(_handle.player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
            child: failure == null
                ? _handle.view
                : Center(
                    child: AppErrorState(
                      message: failure.embeddingRefused
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

/// The player's own fullscreen view, which a phone may turn landscape for.
class _VideoFullscreen extends ConsumerStatefulWidget {
  const _VideoFullscreen({required this.view});

  final Widget view;

  @override
  ConsumerState<_VideoFullscreen> createState() => _VideoFullscreenState();
}

class _VideoFullscreenState extends ConsumerState<_VideoFullscreen> {
  late final PhoneLandscapeHold _landscape;

  @override
  void initState() {
    super.initState();
    _landscape = PhoneLandscapeHold(
      ref.read(orientationChannelProvider),
      ref.read(portraitLockedPhoneProvider.notifier),
    );
    unawaited(_landscape.enter());
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  @override
  void dispose() {
    _landscape.release();
    unawaited(drawUnderSystemBars());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: const Color(0xFF000000), child: widget.view);
}
