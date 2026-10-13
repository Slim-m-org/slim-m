// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Swaps the app for just the call's video while the OS floats it as a
/// picture-in-picture window.
///
/// The routed app stays mounted, only hidden and paused, so leaving the window
/// lands back on the same screen and scroll position. The video is the view the
/// call screen and mini-player already render, never a second subscription.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/call_mini_player.dart';
import '../providers/picture_in_picture.dart';
import '../providers/voice_controller.dart';

/// The feed filling the floating window; exposed for tests.
const pictureInPictureFeedKey = Key('picture_in_picture_feed');

class PictureInPictureGate extends ConsumerWidget {
  const PictureInPictureGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pictureInPictureHostProvider);
    final feed = ref.watch(pictureInPictureFeedProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        TickerMode(
          enabled: feed == null,
          child: Offstage(offstage: feed != null, child: child),
        ),
        if (feed != null) Positioned.fill(child: _FloatingFeed(feed: feed)),
      ],
    );
  }
}

class _FloatingFeed extends ConsumerWidget {
  const _FloatingFeed({required this.feed});

  final MiniPlayerFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(voiceControllerProvider.notifier);
    final view = switch (feed.kind) {
      FeedKind.screenShare => controller.screenShareViewFor(feed.identity),
      FeedKind.camera => controller.cameraViewFor(feed.identity),
    };
    return ColoredBox(
      key: pictureInPictureFeedKey,
      color: Colors.black,
      child: IgnorePointer(child: view),
    );
  }
}
