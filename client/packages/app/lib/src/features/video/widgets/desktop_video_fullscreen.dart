// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop player fullscreen: a root route over the whole window, which
/// the player's fullscreen hold has already made fullscreen. It leaves when
/// the page does, and Escape or the back action take the page out.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/desktop_video.dart';
import '../providers/desktop_video_player.dart';
import 'desktop_video_view.dart';

Future<void> showDesktopVideoFullscreen(
  BuildContext context,
  DesktopVideoPlayer player,
) => Navigator.of(context, rootNavigator: true).push<void>(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => _DesktopVideoFullscreen(player: player),
  ),
);

class _DesktopVideoFullscreen extends ConsumerStatefulWidget {
  const _DesktopVideoFullscreen({required this.player});

  final DesktopVideoPlayer player;

  @override
  ConsumerState<_DesktopVideoFullscreen> createState() =>
      _DesktopVideoFullscreenState();
}

class _DesktopVideoFullscreenState
    extends ConsumerState<_DesktopVideoFullscreen> {
  late final ValueListenable<bool> _fullscreen;

  @override
  void initState() {
    super.initState();
    _fullscreen = ref.read(desktopVideoProvider.notifier).fullscreen
      ..addListener(_onFullscreen);
  }

  void _onFullscreen() {
    if (!_fullscreen.value && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _fullscreen.removeListener(_onFullscreen);
    if (_fullscreen.value) unawaited(widget.player.exitFullscreen());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: Colors.black,
          child: DesktopVideoView(player: widget.player, fullscreenRoute: true),
        ),
      ),
    );
  }
}
