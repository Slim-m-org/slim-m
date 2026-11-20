// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone player's own fullscreen: the page asked for it, so its view moves
/// to a route of its own, the one time a portrait-locked phone may turn (0058).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/phone_landscape.dart';
import '../../../widgets/system_bars.dart';

/// Shows and takes down one player's fullscreen route.
class VideoFullscreenRoute {
  NavigatorState? _navigator;
  bool _on = false;

  void show(BuildContext context, Widget view, void Function() onExit) {
    if (_on) return;
    _on = true;
    final navigator = _navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      navigator
          .push(
            PageRouteBuilder<void>(
              opaque: true,
              pageBuilder: (_, _, _) => _VideoFullscreen(view: view),
            ),
          )
          .then((_) {
            if (_on) {
              _on = false;
              onExit();
            }
          }),
    );
  }

  void hide() {
    if (!_on) return;
    _on = false;
    _navigator?.pop();
  }

  /// For the owner's dispose, while the tree is locked.
  void dispose() {
    if (!_on) return;
    _on = false;
    final navigator = _navigator;
    // The tree is locked while the owner disposes, so the route leaves after the frame.
    SchedulerBinding.instance.addPostFrameCallback((_) => navigator?.pop());
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
