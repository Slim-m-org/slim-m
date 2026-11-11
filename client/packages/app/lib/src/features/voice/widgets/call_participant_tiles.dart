// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call participant tiles, and the call-duration readout.
///
/// One tile shape covers every place a participant appears on the call stage;
/// `../layout/stage_fit.dart` sizes it, so it takes a width and a height.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../format.dart';
import 'call_tile_backdrop.dart';
import 'call_tile_badges.dart';
import 'second_clock.dart';
import '../../../widgets/context_menu_region.dart';
import '../../../widgets/double_click_detector.dart';
import '../../members/widgets/user_avatar.dart';
import 'video_label_pill.dart';

export 'call_tile_badges.dart'
    show
        deafenedBadgeKey,
        hiddenShareBadgeKey,
        poorConnectionBadgeKey,
        poorConnectionLabel,
        poorConnectionMessage;

/// The caption a tile shows while its camera is on but has no frame yet.
const cameraStartingKey = Key('call_tile_camera_starting');

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

/// Below this a tile has no room for "(you)" beside a name.
const double _kYouLabelMinWidth = 112;

/// Room the name label and its padding take at the tile's bottom edge.
const double _kCallTileLabelBand = 36;

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
    this.height,
    this.contextMenuItemsBuilder,
    this.poorConnection = false,
    this.shareHidden = false,
  });

  final VoiceParticipant participant;

  /// Whether this person's audio is breaking up; the tile then says so quietly.
  final bool poorConnection;

  /// Whether this person is sharing a screen the viewer stopped watching.
  final bool shareHidden;

  /// How wide this tile renders, video box and avatar included - the name
  /// label and mute badge stay their own fixed size regardless. Callers
  /// pass a size fit to the available room; see [callGridTileWidth].
  final double width;

  /// The tile's height; null keeps the call tile's own 5:8 ratio to [width].
  final double? height;

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
      if (participant.isScreenSharing)
        shareHidden ? 'sharing their screen, hidden' : 'sharing their screen',
    ];
    return parts.join(', ');
  }

  /// A live feed is only worth showing - and expanding - while the flag it
  /// answers for is itself true; a stale `cameraView` handed down the frame
  /// a camera turned off would otherwise still render.
  bool get _showsCamera => cameraView != null && participant.isCameraOn;

  // The name gives way before "(you)" does, so a long name still says whose tile it is.
  Widget _label(Color colour, {required bool onVideo}) {
    final nameStyle = AppText.ui.copyWith(color: colour);
    final name = Row(
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
        if (participant.isLocal && width >= _kYouLabelMinWidth)
          Text(' (you)', style: nameStyle),
      ],
    );
    if (!onVideo) return name;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Flexible(child: VideoLabelPill(child: name))],
    );
  }

  /// [feed] is whether a decoded camera frame is showing; until then the camera
  /// stays mounted under a [fill] cover so it can start, and the avatar stays.
  Widget _face(
    AppTokens tokens,
    Color onFace,
    double avatarSize,
    Color fill, {
    bool feed = false,
  }) => Stack(
    children: [
      if (_showsCamera)
        Positioned.fill(
          child: CameraFitScope(
            fit: CameraFit.coverUnlessPortrait,
            child: cameraView!,
          ),
        ),
      if (_showsCamera && !feed)
        Positioned.fill(child: ColoredBox(color: fill)),
      if (!feed)
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          bottom: _kCallTileLabelBand,
          child: Center(
            child: UserAvatar(
              key: callTileAvatarKey,
              name: participant.name,
              userId: participant.identity,
              size: avatarSize,
            ),
          ),
        ),
      if (_showsCamera && !feed)
        Positioned(
          left: AppSpacing.s8,
          top: AppSpacing.s8,
          width: width - 4 * AppSpacing.s8 - AppSpacing.s16,
          child: Text(
            'Starting camera',
            key: cameraStartingKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: onFace),
          ),
        ),
      Positioned(
        left: AppSpacing.s8,
        right: AppSpacing.s8,
        bottom: AppSpacing.s12,
        child: _label(
          _showsCamera ? tokens.textPrimary : onFace,
          onVideo: _showsCamera,
        ),
      ),
      // Top corner, so the name keeps the tile's whole width and its "(you)".
      Positioned(
        right: AppSpacing.s8,
        top: AppSpacing.s8,
        child: TileStateBadges(
          participant: participant,
          shareHidden: shareHidden,
          stacked: !feed && badgesReachAvatar(width, avatarSize, participant),
        ),
      ),
      // Last, so the sentence it opens paints over the state badges.
      if (poorConnection && !participant.isLocal)
        Positioned(
          left: AppSpacing.s8,
          top: AppSpacing.s8,
          child: PoorConnectionBadge(
            participant: participant,
            maxTextWidth: width - 2 * AppSpacing.s8,
          ),
        ),
    ],
  );

  Widget _body(AppTokens tokens, double avatarSize) {
    Widget backdrop({required bool feed}) => CallTileBackdrop(
      identity: participant.identity,
      builder: (_, onFace, fill) =>
          _face(tokens, onFace, avatarSize, fill, feed: feed),
    );
    if (!_showsCamera) return backdrop(feed: false);
    return CameraFrameScope(builder: (_, hasFrame) => backdrop(feed: hasFrame));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final height = this.height ?? width * _kCallTileAspect;
    final avatarSize = AppAvatarSize.largestWithin(
      height - _kCallTileLabelBand - AppSpacing.s8,
    );
    // This build's own context, so a popover anchors to this tile - see [onTap]'s doc.
    final onTapHere = onTap == null ? null : () => onTap!(context);
    // The whole tile carries speaking, camera or not, so it reads from across a busy grid.
    final ringsTile = participant.isSpeaking;
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
                child: DecoratedBox(
                  // Outside the clip below, which would cut the glow off at the tile's edge.
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadii.card),
                    boxShadow: ringsTile
                        ? [
                            BoxShadow(
                              color: tokens.accent.withValues(alpha: 0.55),
                              blurRadius: 16,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.card),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: ringsTile
                            ? Border.all(color: tokens.accent, width: 2)
                            : Border.all(color: tokens.borderSubtle),
                        borderRadius: BorderRadius.circular(AppRadii.card),
                      ),
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: _body(tokens, avatarSize),
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
