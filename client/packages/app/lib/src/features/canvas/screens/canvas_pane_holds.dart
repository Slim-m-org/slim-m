// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the canvas pane holds while a call tile fills it: the window in full
/// screen, a phone turned to landscape, and the tile's video at full sharpness.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../desktop/desktop_window_shell.dart';
import '../../../desktop/window_fullscreen_hold.dart';
import '../../../providers/phone_landscape.dart';
import '../../voice/providers/fullscreen_video.dart';
import '../../voice/providers/voice_controller.dart';
import '../providers/canvas_focus_video_hold.dart';
import 'canvas_fullscreen.dart';

class CanvasPaneHolds {
  /// Build it in `initState`: `dispose` cannot read ref, and releasing the window must still work then.
  CanvasPaneHolds(WidgetRef ref, {required String Function() channelId})
    : _window = WindowFullscreenHold(
        ref.read(fullscreenVideoActiveProvider.notifier),
        ref.read(desktopWindowShellProvider),
      ),
      _landscape = PhoneLandscapeHold(
        ref.read(orientationChannelProvider),
        ref.read(portraitLockedPhoneProvider.notifier),
      ),
      _focusVideo = CanvasFocusVideoHold(
        ref.read(voiceControllerProvider.notifier).video.holdEnlargedVideo,
      ) {
    ref.listenManual(
      canvasFocusedTileProvider,
      (_, focus) => _focusVideo.follow(focusedTileOf(focus, channelId())),
      fireImmediately: true,
    );
  }

  final WindowFullscreenHold _window;
  final PhoneLandscapeHold _landscape;
  final CanvasFocusVideoHold _focusVideo;

  void enter() {
    unawaited(_window.enter());
    unawaited(_landscape.enter());
  }

  void release() {
    _window.release();
    _landscape.release();
  }

  /// Lets go of everything, the focused tile's video included.
  void dispose() {
    release();
    _focusVideo.release();
  }
}
