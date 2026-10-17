// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Full screen playback for an attachment video, opened from the inline
/// player in the transcript.
///
/// The route is handed the same `Player`/`VideoController` the inline frame
/// already owns rather than opening a second one: both this route's [Video]
/// and the inline one it was pushed from can render the same live texture at
/// once (this is the same trick `media_kit_video`'s own built-in fullscreen
/// button uses internally), so entering and leaving full screen never
/// restarts playback or re-buffers the clip.
///
/// Modelled on `fullscreen_video_overlay.dart`'s shape (a root-navigator
/// route, a dark `Theme`, a header with a close control, Escape wired
/// through `CallbackShortcuts`) for the same reason that file gives:
/// consistency with the app's one other full-bleed video surface, not a
/// second design.
///
/// Swipe-down-to-dismiss is [SwipeDownToDismiss], the same tracked-drag
/// shape `fullscreen_image_viewer.dart` already uses for a photo (the frame
/// follows the finger via `Transform.translate` and either snaps back or
/// dismisses on release) rather than firing on a binary fling, since a
/// tracked dismissal is what makes the gesture read as native. It is its own
/// widget, not inlined here, so a test can drive it against a plain child
/// rather than a real video texture - see `swipe_down_to_dismiss_test.dart`.
/// It is gated on [AppTouchTargets.of] rather than every pointer kind, per
/// `desktop-vs-mobile.md`'s core rule: a mouse drag on a narrow desktop
/// window is the same situation as a touch drag on a phone, and a pointer
/// user on a wide window already has the close button, Escape, and the
/// bar's own full screen toggle.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/swipe_down_to_dismiss.dart';
import '../../../widgets/video_playback_controls.dart';

/// Opens [filename]'s clip full screen, sharing [player]/[controller] with
/// whatever inline frame is already showing it.
Future<void> showFullscreenAttachmentVideo(
  BuildContext context, {
  required Player player,
  required VideoController controller,
  required String filename,
}) {
  final duration = AppMotion.reduced(context, AppMotion.base);
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: duration,
      reverseTransitionDuration: duration,
      pageBuilder: (_, animation, _) => FadeTransition(
        opacity: animation,
        child: AttachmentVideoFullscreen(
          player: player,
          controller: controller,
          filename: filename,
        ),
      ),
    ),
  );
}

class AttachmentVideoFullscreen extends StatefulWidget {
  const AttachmentVideoFullscreen({
    super.key,
    required this.player,
    required this.controller,
    required this.filename,
  });

  final Player player;
  final VideoController controller;
  final String filename;

  @override
  State<AttachmentVideoFullscreen> createState() =>
      _AttachmentVideoFullscreenState();
}

class _AttachmentVideoFullscreenState extends State<AttachmentVideoFullscreen> {
  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final touchGestures = AppTouchTargets.of(context);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: Theme(
          data: buildTheme(Brightness.dark, AppTokens.dark),
          child: Material(
            type: MaterialType.transparency,
            child: ColoredBox(
              color: Colors.black,
              child: SafeArea(
                child: Column(
                  children: [
                    _FullscreenVideoHeader(
                      filename: widget.filename,
                      onClose: _close,
                    ),
                    Expanded(
                      child: SwipeDownToDismiss(
                        enabled: touchGestures,
                        onDismiss: _close,
                        child: VideoPlaybackControls(
                          player: widget.player,
                          isFullscreen: true,
                          onToggleFullscreen: _close,
                          // No default media_kit chrome; see video_playback_controls.dart's doc.
                          child: Video(
                            controller: widget.controller,
                            controls: null,
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

class _FullscreenVideoHeader extends StatelessWidget {
  const _FullscreenVideoHeader({required this.filename, required this.onClose});

  final String filename;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textSecondary),
            ),
          ),
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Close video',
            size: AppIconButtonSize.touch,
            touch: true,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
