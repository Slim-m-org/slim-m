// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks a call tile draws in its corners: deafened, muted, sharing, and
/// a connection that is breaking up.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'video_label_pill.dart';

/// What a poor-connection mark says about [p], on a tile or a roster avatar.
String poorConnectionLabel(VoiceParticipant p) =>
    p.isLocal ? 'your connection is unstable' : 'connection is unstable';

/// [poorConnectionLabel] as a sentence, for text a person reads.
String poorConnectionMessage(VoiceParticipant p) {
  final label = poorConnectionLabel(p);
  return '${label[0].toUpperCase()}${label.substring(1)}.';
}

/// The unstable-connection glyph on a call tile, for tests to find.
const poorConnectionBadgeKey = ValueKey('participant-poor-connection-badge');

/// The deafened glyph on a call tile, for tests to find.
const deafenedBadgeKey = ValueKey('participant-deafened-badge');

/// The muted glyph on a call tile, for tests to find.
const mutedBadgeKey = ValueKey('participant-muted-badge');

/// The sharing glyph on a call tile, for tests to find.
const sharingBadgeKey = ValueKey('participant-sharing-badge');

/// The glyph a tile shows for a share the viewer stopped watching, for tests to find.
const hiddenShareBadgeKey = ValueKey('participant-hidden-share-badge');

/// A tile's avatar, for tests to find.
const callTileAvatarKey = ValueKey('call-tile-avatar');

/// The text a tapped poor-connection glyph opens, for tests to find.
const poorConnectionMessageKey = ValueKey('participant-poor-connection-text');

const double _kBadgeSize = 22;

/// The round chip every tile badge sits in.
Widget _badgeCircle(AppTokens tokens, Widget icon) => Container(
  width: _kBadgeSize,
  height: _kBadgeSize,
  alignment: Alignment.center,
  decoration: BoxDecoration(
    color: tokens.surfaceRaised,
    shape: BoxShape.circle,
    border: Border.all(color: tokens.borderSubtle),
  ),
  child: icon,
);

bool _showsMicBadge(VoiceParticipant p) => p.isMuted || !p.isScreenSharing;

/// How many badges [p]'s tile draws: deafened, the mic (muted, or live while
/// not sharing) and sharing.
int tileBadgeCount(VoiceParticipant p) =>
    (p.isDeafened ? 1 : 0) +
    (_showsMicBadge(p) ? 1 : 0) +
    (p.isScreenSharing ? 1 : 0);

/// Whether a row of [p]'s badges, anchored at the top right of a tile
/// [width] wide, would run under an avatar of [avatarSize] centred in it.
bool badgesReachAvatar(double width, double avatarSize, VoiceParticipant p) {
  final count = tileBadgeCount(p);
  final row = count * _kBadgeSize + (count - 1) * AppSpacing.s4;
  return width - AppSpacing.s8 - row < (width + avatarSize) / 2;
}

/// A tile's state badges, in a row or - when a row would run under the
/// avatar - a column.
class TileStateBadges extends StatelessWidget {
  const TileStateBadges({
    super.key,
    required this.participant,
    required this.stacked,
    this.shareHidden = false,
  });

  final VoiceParticipant participant;
  final bool stacked;

  /// Whether this viewer stopped watching the participant's share, which the
  /// sharing badge then says instead of the live share glyph.
  final bool shareHidden;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final p = participant;
    return Flex(
      direction: stacked ? Axis.vertical : Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s4,
      children: [
        if (p.isDeafened)
          _badgeCircle(
            tokens,
            Icon(
              AppIcons.headphonesOff,
              key: deafenedBadgeKey,
              size: 12,
              color: tokens.textSecondary,
            ),
          ),
        if (_showsMicBadge(p))
          _badgeCircle(
            tokens,
            Icon(
              p.isMuted ? AppIcons.micOff : AppIcons.mic,
              key: p.isMuted ? mutedBadgeKey : null,
              size: 12,
              color: p.isMuted ? tokens.textSecondary : tokens.accent,
            ),
          ),
        if (p.isScreenSharing)
          _badgeCircle(
            tokens,
            Icon(
              shareHidden ? AppIcons.tileHide : AppIcons.screenShare,
              key: shareHidden ? hiddenShareBadgeKey : sharingBadgeKey,
              size: 12,
              color: shareHidden ? tokens.textSecondary : tokens.accent,
            ),
          ),
      ],
    );
  }
}

/// A tile's poor-connection glyph. Tapping it opens the sentence the glyph
/// stands for in place, since a hover tooltip would not reach a finger.
class PoorConnectionBadge extends StatefulWidget {
  const PoorConnectionBadge({
    super.key,
    required this.participant,
    required this.maxTextWidth,
  });

  final VoiceParticipant participant;

  /// The widest the opened sentence may grow, the tile's width less its margins.
  final double maxTextWidth;

  @override
  State<PoorConnectionBadge> createState() => _PoorConnectionBadgeState();
}

class _PoorConnectionBadgeState extends State<PoorConnectionBadge> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s4,
      children: [
        AppTouchHitArea(
          alignment: Alignment.topLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: _badgeCircle(
              tokens,
              Icon(
                AppIcons.connectionPoor,
                key: poorConnectionBadgeKey,
                size: 12,
                color: tokens.warnText,
              ),
            ),
          ),
        ),
        if (_open)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxTextWidth),
            child: VideoLabelPill(
              child: Text(
                poorConnectionMessage(widget.participant),
                key: poorConnectionMessageKey,
                style: AppText.caption.copyWith(color: tokens.textPrimary),
              ),
            ),
          ),
      ],
    );
  }
}
