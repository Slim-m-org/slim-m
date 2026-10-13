// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stage a peer's shared screen renders on during a call.
///
/// Its own file rather than more of `voice_screen.dart`, which was over the
/// review budget before this existed. The video itself comes through
/// `VoiceController.screenShareViewFor`, so this file stays free of LiveKit
/// types like everything else outside the rtc package.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_mini_player.dart';
import 'double_click_detector.dart';
import 'fullscreen_video_overlay.dart';
import 'media_label.dart';
import 'popout_video_button.dart';

/// A dark stage with the share inside it, labelled on hover.
///
/// Black behind the video on purpose, in both themes: a shared screen is
/// arbitrary content, and any chrome tone bleeding around its letterbox reads
/// as part of the screen. The label says whose screen it is, because two
/// people can share in turn and a bare rectangle does not say which.
///
/// That label used to sit in the layout flow underneath the stage, which put
/// it outside the rounded container and left it permanently on. It is now a
/// [MediaLabelChip] inside the clip, revealed by [PointerRevealed] on the same
/// terms as the canvas tile's own - hiding it in place instead would reflow
/// the video every time a pointer crossed it.
///
/// The local caption reads as a full sentence ("You are sharing your
/// screen") rather than a bare label ("Your screen"): it is what is left to
/// confirm a live share once `local_screen_share_banner.dart`'s own banner
/// is withheld here to avoid saying the identical thing twice.
class ScreenShareStage extends StatelessWidget {
  const ScreenShareStage({
    super.key,
    required this.sharerName,
    required this.child,
    this.isLocal = false,
    this.onExpand,
    this.popOutIdentity,
  });

  final String sharerName;

  /// Whether this is the local caller's own share, so the caption reads
  /// "Your screen" rather than the caller's own name reflected back.
  final bool isLocal;

  /// The live share view, from `VoiceController.screenShareViewFor`.
  final Widget child;

  /// Opens this share full screen. Null only in the tests that build this
  /// widget in isolation with nothing behind it to expand into.
  final VoidCallback? onExpand;

  /// The remote sharer's identity, which offers the pop-out button; null for
  /// the local share, which is never previewed back to the sharer.
  final String? popOutIdentity;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return PointerRevealed(
      builder: (context, revealed) => DoubleClickDetector(
        onDoubleClick: onExpand,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadii.card),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF000000),
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: BorderRadius.circular(AppRadii.card),
                  ),
                  child: child,
                ),
              ),
              if (onExpand != null)
                Positioned(
                  left: 4,
                  top: 4,
                  child: ExpandVideoButton(
                    label: isLocal
                        ? 'View your screen full screen'
                        : "View $sharerName's screen full screen",
                    onTap: onExpand!,
                  ),
                ),
              if (popOutIdentity != null && !isLocal)
                Positioned(
                  left: 36,
                  top: 4,
                  child: PopOutVideoButton(
                    feed: (
                      identity: popOutIdentity!,
                      name: sharerName,
                      kind: FeedKind.screenShare,
                    ),
                  ),
                ),
              Positioned(
                left: 6,
                bottom: 6,
                right: 6,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: RevealFade(
                    revealed: revealed,
                    child: MediaLabelChip(
                      icon: AppIcons.screenShare,
                      label: isLocal
                          ? 'You are sharing your screen'
                          : "$sharerName's screen",
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
