// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a camera or screen-share tile shows, split in two so the ink can paint
/// between them: the video body paints in `CanvasPresenceBackdrop` under the
/// ink, and the name badge paints in `CanvasPresenceLayer` above it.
///
/// Purely visual: nothing here knows it is draggable, resizable, lockable or
/// hideable - that is `canvas_presence_tile.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../messages/widgets/media_label.dart';
import 'canvas_presence_geometry.dart' show presenceScreenLabel;

/// A camera tile's live video in its tile chrome. A tile only exists while the
/// camera is on, so there is no avatar fallback here: people without a feed
/// are in the dock's roster instead (decision 0086).
class CanvasPresenceBubble extends StatelessWidget {
  const CanvasPresenceBubble({super.key, required this.cameraView});

  final Widget cameraView;

  @override
  Widget build(BuildContext context) => _TileChrome(
    body: DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF000000)),
      child: cameraView,
    ),
  );
}

/// A screen-share tile's live video in its tile chrome.
class CanvasScreenShareBubble extends StatelessWidget {
  const CanvasScreenShareBubble({super.key, required this.view});

  final Widget view;

  @override
  Widget build(BuildContext context) => _TileChrome(
    body: DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF000000)),
      child: view,
    ),
  );
}

/// The name and mic state over a camera tile's corner.
class CanvasCameraBadge extends StatelessWidget {
  const CanvasCameraBadge({super.key, required this.participant});

  final VoiceParticipant participant;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _BadgeCorner(
      child: MediaLabelChip(
        label: participant.isLocal
            ? '${participant.name} (you)'
            : participant.name,
        icon: participant.isMuted ? AppIcons.micOff : AppIcons.mic,
        iconColor: participant.isMuted ? tokens.textSecondary : tokens.accent,
      ),
    );
  }
}

/// A screen share's name badge.
///
/// It shows on hover rather than sitting permanently over the share, since a
/// permanent chip crowded the video. Hover is an input capability, not a width
/// one, so [PointerRevealed] reads the mouse tracker: on a pure touch device it
/// stays always-on rather than becoming unreachable information.
class CanvasScreenShareBadge extends StatelessWidget {
  const CanvasScreenShareBadge({super.key, required this.participant});

  final VoiceParticipant participant;

  @override
  Widget build(BuildContext context) => PointerRevealed(
    interactive: true,
    builder: (context, revealed) => _BadgeCorner(
      child: RevealFade(
        revealed: revealed,
        child: MediaLabelChip(
          icon: AppIcons.screenShare,
          label: presenceScreenLabel(participant),
        ),
      ),
    ),
  );
}

class _BadgeCorner extends StatelessWidget {
  const _BadgeCorner({required this.child});

  final Widget child;

  // Clipped to the tile's rounded edge, as the badge was when it sat inside the video's own clip.
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.window),
      child: Stack(children: [Positioned(left: 6, bottom: 6, child: child)]),
    ),
  );
}

class _TileChrome extends StatelessWidget {
  const _TileChrome({required this.body});

  final Widget body;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      // AppRadii.window with AppShadows.canvasTile: a tile floats over the grid, but permanently, so it takes the resting-tile lift rather than float's picked-up one.
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.window),
        boxShadow: AppShadows.canvasTile,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.window),
        child: Container(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: body,
        ),
      ),
    );
  }
}
