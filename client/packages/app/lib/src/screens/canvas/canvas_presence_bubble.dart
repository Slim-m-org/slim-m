// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two kinds of content a presence tile can show - a camera and an
/// avatar fallback, or a screen share - split out of `canvas_presence_layer
/// .dart` once wiring screen share and manipulation pushed it past the
/// 300-line review budget. Purely visual: neither widget here knows it is
/// draggable, resizable, lockable or hideable - that is
/// `canvas_presence_tile.dart`'s `CanvasPresenceManipulableTile`, which
/// wraps whichever of these two it is given.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../widgets/media_label.dart';
import '../../widgets/user_avatar.dart';
import 'canvas_presence_geometry.dart' show presenceScreenLabel;

/// One participant's camera tile: their live camera when it is on, or -
/// report 4 in the backlog channel, "if a user is not screen sharing or
/// sharing their camera it should not be a big square, it should just be
/// some sort of representation of them" - their plain avatar with no card
/// around it otherwise. A shrunken video tile was tried first
/// (`presenceCameraOffSize`, still the box this marker sits in for drag and
/// resize purposes) and rejected by the same report: still a box, just a
/// smaller one, where the ask was a different shape of thing entirely.
class CanvasPresenceBubble extends StatelessWidget {
  const CanvasPresenceBubble({
    super.key,
    required this.participant,
    this.cameraView,
  });

  final VoiceParticipant participant;
  final Widget? cameraView;

  bool get _showsCamera => cameraView != null && participant.isCameraOn;

  @override
  Widget build(BuildContext context) {
    if (!_showsCamera) {
      return _AvatarMarker(participant: participant);
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _TileChrome(
      tokens: tokens,
      body: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0xFF000000)),
        child: cameraView,
      ),
      badge: MediaLabelChip(
        label: participant.isLocal
            ? '${participant.name} (you)'
            : participant.name,
        icon: participant.isMuted ? AppIcons.micOff : AppIcons.mic,
        iconColor: participant.isMuted ? tokens.textSecondary : tokens.accent,
      ),
    );
  }
}

/// The whole footprint an avatar-only tile ever paints at - see
/// `canvas_presence_tile.dart`'s own `fixedRenderSize`, which is what reads
/// this. Not just [_AvatarMarker._avatarSize]: the avatar circle sits above
/// its own `AppSpacing.s4` gap and a name pill (one caption line inside its
/// own vertical padding), and a box exactly avatar-sized would clip that
/// pill's layout rather than merely crop its paint. Fixed regardless of
/// zoom or of whatever size a video tile sharing this same server-side slot
/// was once resized to - report 4's own ask, "the pfp should not be broken
/// or resizeable," taken literally.
const canvasAvatarMarkerSize = Size(112, 96);

/// No card, no border, no shadow, no fixed-colour background: just the
/// avatar this participant already has everywhere else in the app (the
/// member list, a message row), a small muted glyph over its own corner
/// rather than a second badge bar, and their name in plain text underneath.
/// The one thing this still needs from the tile chrome it replaces is a
/// name - unlike a member-list row, a canvas can hold several of these at
/// once with nothing else on screen saying whose avatar is whose. That name
/// sits on a translucent pill, matching [MediaLabelChip]'s own background: a
/// marker can land over anything on the canvas, ink included, and a plain
/// drop shadow tuned for the empty background loses to a light note fill
/// directly underneath it.
class _AvatarMarker extends StatelessWidget {
  const _AvatarMarker({required this.participant});

  final VoiceParticipant participant;

  static const double _avatarSize = AppAvatarSize.s56;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              UserAvatar(
                name: participant.name,
                userId: participant.identity,
                size: _avatarSize,
                speaking: participant.isSpeaking,
              ),
              if (participant.isMuted)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    // Off-grid on purpose: rounding to 4 would grow this corner badge past the avatar it sits on.
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: tokens.surfaceRaised,
                      shape: BoxShape.circle,
                      border: Border.all(color: tokens.surfaceBase, width: 2),
                    ),
                    child: Icon(
                      AppIcons.micOff,
                      size: 12,
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.s4),
          // See the class doc above for why this is a pill, not a shadow.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s8,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceBase.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(AppRadii.full),
            ),
            child: Text(
              participant.isLocal
                  ? '${participant.name} (you)'
                  : participant.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A screen-share tile: no speaking ring or mic glyph, since sharing a
/// screen carries no audio state of its own worth badging - only whose
/// screen it is.
///
/// The name badge shows on hover rather than sitting permanently over the
/// share - report directly from the owner: a permanent chip crowded the
/// video underneath it. Hover is an input capability, not a width one (this
/// file otherwise never branches on anything but layout), so it is read from
/// [RendererBinding.mouseTracker] rather than a platform check: whenever a
/// hover-capable pointer is connected, the badge stays hidden until this
/// tile is actually hovered; on a pure touch device, where hover can never
/// fire, it stays always-on rather than becoming unreachable information -
/// someone joining mid-call still has to be able to tell whose screen this
/// is. [interactive] is false for the one context that can never hover at
/// all: a tile sent to back and painted through `CanvasPresenceBackdrop`,
/// which is `IgnorePointer`-wrapped end to end, so the badge stays always-on
/// there too rather than a reveal nothing can ever trigger.
class CanvasScreenShareBubble extends StatefulWidget {
  const CanvasScreenShareBubble({
    super.key,
    required this.participant,
    required this.view,
    this.interactive = true,
  });

  final VoiceParticipant participant;
  final Widget view;
  final bool interactive;

  @override
  State<CanvasScreenShareBubble> createState() =>
      _CanvasScreenShareBubbleState();
}

class _CanvasScreenShareBubbleState extends State<CanvasScreenShareBubble> {
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return PointerRevealed(
      interactive: widget.interactive,
      builder: (context, revealed) => _TileChrome(
        tokens: tokens,
        body: DecoratedBox(
          decoration: const BoxDecoration(color: Color(0xFF000000)),
          child: widget.view,
        ),
        badge: RevealFade(
          revealed: revealed,
          child: MediaLabelChip(
            icon: AppIcons.screenShare,
            label: presenceScreenLabel(widget.participant),
          ),
        ),
      ),
    );
  }
}

class _TileChrome extends StatelessWidget {
  const _TileChrome({required this.tokens, required this.body, this.badge});

  final AppTokens tokens;
  final Widget body;
  final Widget? badge;

  @override
  Widget build(BuildContext context) => Container(
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
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(child: body),
            if (badge != null) Positioned(left: 6, bottom: 6, child: badge!),
          ],
        ),
      ),
    ),
  );
}
