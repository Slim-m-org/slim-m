// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call participant tiles, and the call-duration readout.
///
/// A call used to render as a top-anchored list of small rows over a mostly
/// empty pane, which read as a debug view rather than a place people are.
/// One tile shape now covers both places a participant can appear -
/// `call_stage_layout.dart`'s centred grid when nobody is sharing, and its
/// horizontal filmstrip beneath the stage when somebody is - but the grid's
/// tiles no longer sit at one fixed size: [callGridTileWidth] grows them for
/// a two-person call and shrinks them back down past eight, so the room
/// this product is built for reads as a room rather than a debug view no
/// matter how many of the two-to-twelve show up. The filmstrip keeps the
/// original fixed size - it is already correct, since a screen share is
/// already holding the room.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../format.dart';
import 'call_tile_backdrop.dart';
import 'second_clock.dart';
import '../../../widgets/context_menu_region.dart';
import '../../../widgets/double_click_detector.dart';
import '../../members/widgets/user_avatar.dart';

/// The participant menu's width, room enough for its volume slider.
const double kParticipantMenuWidth = 248;

/// The tile's size floor: the original fixed width, still right once a call
/// is full enough that more room per tile would not help.
const double kCallTileMinWidth = 144;

/// The tile's size ceiling: past this, more room reads as air around a face
/// rather than a bigger one.
const double kCallTileMaxWidth = 320;

/// The tile's height as a fraction of its width: 320x200 at the ceiling.
const double _kCallTileAspect = 0.625;

/// Room the name label and its padding take at the tile's bottom edge.
const double _kCallTileLabelBand = 36;

/// How wide one grid tile should render for [count] participants inside
/// [constraints] - the fixed 112px tile made a two-person call look like
/// two small faces in a big empty room; this instead grows tiles to fill
/// the space a small roster leaves, and shrinks them back down once a
/// bigger roster needs the room. Reads window/pane constraints only, never
/// `Platform.isX` - desktop-vs-mobile rule 1, width decides.
///
/// Tries every column count from one tile per row to one row of tiles, and
/// keeps the widest tile that still fits both [constraints] dimensions -
/// the same grid-packing a video call's own tile layout needs elsewhere,
/// cheap here because a call this product is built for never seats more
/// than a handful of people.
double callGridTileWidth(
  BoxConstraints constraints,
  int count, {
  double spacing = AppSpacing.s16,
}) {
  if (count <= 0) return kCallTileMinWidth;
  final maxWidth = constraints.maxWidth.isFinite
      ? constraints.maxWidth
      : kCallTileMaxWidth;
  final maxHeight = constraints.maxHeight;
  var best = kCallTileMinWidth;
  for (var columns = 1; columns <= count; columns++) {
    final rows = (count / columns).ceil();
    var candidate = (maxWidth - (columns - 1) * spacing) / columns;
    if (maxHeight.isFinite) {
      final rowHeight = (maxHeight - (rows - 1) * spacing) / rows;
      final fromHeight = rowHeight / _kCallTileAspect;
      if (fromHeight < candidate) candidate = fromHeight;
    }
    if (candidate > best) best = candidate;
  }
  return best.clamp(kCallTileMinWidth, kCallTileMaxWidth);
}

/// One participant as a tile: a large avatar with the speaking ring, the
/// name beneath, and the mute or share state as a small badge - or, once a
/// camera is actually on, the live feed in place of the avatar. [cameraView]
/// is passed for the local participant too now (`call_stage_layout.dart`
/// builds every tile the same way), so there is no separate enlarged
/// self-preview outside this grid any more.
class CallParticipantTile extends StatelessWidget {
  const CallParticipantTile({
    super.key,
    required this.participant,
    this.onTap,
    this.cameraView,
    this.onExpand,
    this.width = kCallTileMinWidth,
    this.contextMenuItemsBuilder,
    this.poorConnection = false,
  });

  final VoiceParticipant participant;

  /// Whether this person's audio is breaking up; the tile then says so quietly.
  final bool poorConnection;

  /// How wide this tile renders, video box and avatar included - the name
  /// label and mute badge stay their own fixed size regardless. Callers
  /// pass a size fit to the available room; see [callGridTileWidth].
  final double width;

  /// Opens this participant's profile.
  ///
  /// Takes this tile's own [BuildContext] - captured here, inside [build],
  /// rather than upstream in whatever list or wrap laid this tile out. A
  /// caller's own itemBuilder context resolves to the list's sliver, not
  /// this tile's box, so a popover anchored from it lands on the wrong
  /// widget entirely.
  final void Function(BuildContext anchor)? onTap;

  /// The volume/mute/profile/moderate rows a right-click or long-press
  /// opens - `participant_call_menu.dart`'s own `participantCallMenuItems`,
  /// shared with the canvas bubble's own context menu so the two never
  /// offer a different set for the same person. Null renders no menu at
  /// all, leaving a right-click inert - the same "absent, never disabled"
  /// shape every other optional row in this app follows.
  final List<Widget> Function(BuildContext, VoidCallback close)?
  contextMenuItemsBuilder;

  /// This participant's live camera feed, from
  /// `VoiceController.cameraViewFor` - null whenever there is nothing to show
  /// in its place, so the avatar renders instead.
  final Widget? cameraView;

  /// Opens [cameraView] full screen. Non-null exactly when [cameraView] is,
  /// since there is nothing to expand into otherwise.
  final VoidCallback? onExpand;

  String get _semanticLabel {
    final parts = <String>[
      participant.isLocal ? '${participant.name}, you' : participant.name,
      participant.isMuted ? 'muted' : 'microphone on',
      if (participant.isDeafened) 'deafened',
      if (poorConnection) poorConnectionLabel(participant),
      if (participant.isSpeaking) 'speaking',
      if (participant.isScreenSharing) 'sharing their screen',
    ];
    return parts.join(', ');
  }

  /// A live feed is only worth showing - and expanding - while the flag it
  /// answers for is itself true; a stale `cameraView` handed down the frame
  /// a camera turned off would otherwise still render.
  bool get _showsCamera => cameraView != null && participant.isCameraOn;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final height = width * _kCallTileAspect;
    final avatarSize = AppAvatarSize.largestWithin(
      height - _kCallTileLabelBand - AppSpacing.s8,
    );
    // This build's own context, so a popover anchors to this tile - see [onTap]'s doc.
    final onTapHere = onTap == null ? null : () => onTap!(context);
    // The name gives way before "(you)" does, so a long name still says whose tile it is.
    Widget label(Color colour) {
      final nameStyle = AppText.ui.copyWith(color: colour);
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              participant.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nameStyle,
            ),
          ),
          if (participant.isLocal) Text(' (you)', style: nameStyle),
        ],
      );
    }

    Widget face(Color onFace) => Stack(
      children: [
        if (_showsCamera)
          Positioned.fill(child: cameraView!)
        else
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: _kCallTileLabelBand,
            child: Center(
              child: UserAvatar(
                name: participant.name,
                userId: participant.identity,
                size: avatarSize,
                speaking: participant.isSpeaking,
              ),
            ),
          ),
        Positioned(
          left: AppSpacing.s8,
          right: AppSpacing.s8,
          bottom: AppSpacing.s12,
          child: label(_showsCamera ? const Color(0xFFFFFFFF) : onFace),
        ),
        if (poorConnection)
          Positioned(
            left: AppSpacing.s8,
            top: AppSpacing.s8,
            child: _PoorConnectionBadge(participant: participant),
          ),
        // Top corner, so the name keeps the tile's whole width and its "(you)".
        Positioned(
          right: AppSpacing.s8,
          top: AppSpacing.s8,
          child: _StateBadge(
            participant: participant,
            stacked:
                !_showsCamera &&
                _badgesReachAvatar(width, avatarSize, participant),
          ),
        ),
      ],
    );
    // A camera hides the avatar that carries the speaking ring, so the tile takes it.
    final ringsTile = _showsCamera && participant.isSpeaking;
    Widget tile = Stack(
      clipBehavior: Clip.none,
      children: [
        Semantics(
          container: true,
          label: _semanticLabel,
          button: onTap != null,
          onTap: onTapHere,
          child: ExcludeSemantics(
            child: GestureDetector(
              onTap: onTapHere,
              child: AnimatedSize(
                duration: AppMotion.reducedSize(context, AppMotion.base),
                curve: AppMotion.entrance,
                alignment: Alignment.topCenter,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.card),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _showsCamera ? const Color(0xFF000000) : null,
                      border: ringsTile
                          ? Border.all(color: tokens.accent, width: 2)
                          : Border.all(color: tokens.borderSubtle),
                      borderRadius: BorderRadius.circular(AppRadii.card),
                    ),
                    child: SizedBox(
                      width: width,
                      height: height,
                      child: _showsCamera
                          ? face(tokens.textPrimary)
                          : CallTileBackdrop(
                              identity: participant.identity,
                              builder: (_, onFace) => face(onFace),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    if (_showsCamera && onExpand != null) {
      tile = DoubleClickDetector(onDoubleClick: onExpand, child: tile);
    }
    if (contextMenuItemsBuilder case final itemsBuilder?) {
      tile = ContextMenuRegion(
        menuWidth: kParticipantMenuWidth,
        itemsBuilder: itemsBuilder,
        child: tile,
      );
    }
    return tile;
  }
}

/// What a poor-connection mark says about [p], on a tile or a roster avatar.
String poorConnectionLabel(VoiceParticipant p) =>
    p.isLocal ? 'your connection is unstable' : 'connection is unstable';

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

bool _badgesReachAvatar(double width, double avatarSize, VoiceParticipant p) {
  final count = p.isDeafened ? 2 : 1;
  final row = count * _kBadgeSize + (count - 1) * AppSpacing.s4;
  return width - AppSpacing.s8 - row < (width + avatarSize) / 2;
}

class _PoorConnectionBadge extends StatelessWidget {
  const _PoorConnectionBadge({required this.participant});

  final VoiceParticipant participant;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Tooltip(
      message: poorConnectionLabel(participant),
      child: _badgeCircle(
        tokens,
        Icon(
          AppIcons.connectionPoor,
          key: poorConnectionBadgeKey,
          size: 12,
          color: tokens.warnText,
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.participant, required this.stacked});

  final VoiceParticipant participant;

  /// Badges stack in a column when a row of them would run under the avatar.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final main = Icon(
      participant.isScreenSharing
          ? AppIcons.screenShare
          : participant.isMuted
          ? AppIcons.micOff
          : AppIcons.mic,
      size: 12,
      color: participant.isMuted ? tokens.textSecondary : tokens.accent,
    );
    return Flex(
      direction: stacked ? Axis.vertical : Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s4,
      children: [
        if (participant.isDeafened)
          _badgeCircle(
            tokens,
            Icon(
              AppIcons.headphonesOff,
              key: deafenedBadgeKey,
              size: 12,
              color: tokens.textSecondary,
            ),
          ),
        _badgeCircle(tokens, main),
      ],
    );
  }
}

/// The unstable-connection glyph on a call tile, for tests to find.
const poorConnectionBadgeKey = ValueKey('participant-poor-connection-badge');

/// The deafened glyph on a call tile, for tests to find.
const deafenedBadgeKey = ValueKey('participant-deafened-badge');

/// The running clock a call shows: `mm:ss`, or `h:mm:ss` past the hour.
String formatCallClock(Duration d) {
  final parts = decomposeDuration(d);
  final m = parts.minutes.toString().padLeft(2, '0');
  final s = parts.seconds.toString().padLeft(2, '0');
  return parts.hours > 0 ? '${parts.hours}:$m:$s' : '$m:$s';
}

/// `12:34`-style elapsed time since [since], ticking once a second.
///
/// A text update, not motion, so it does not route through reduce-motion; it
/// shares one clock with every other readout and pauses when unseen.
class CallDuration extends StatefulWidget {
  const CallDuration({super.key, required this.since, this.style});

  final DateTime since;

  /// Overrides the default caption style, for a header that sets its own.
  final TextStyle? style;

  @override
  State<CallDuration> createState() => _CallDurationState();
}

class _CallDurationState extends State<CallDuration> with SecondTickMixin {
  @override
  Widget build(BuildContext context) {
    tickWhile(true);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final elapsed = DateTime.now().difference(widget.since);
    return Text(
      formatCallClock(elapsed.isNegative ? Duration.zero : elapsed),
      style:
          widget.style ??
          AppText.caption.copyWith(
            color: tokens.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
    );
  }
}
