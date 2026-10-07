// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is here and has no tile of their own, drawn as a small face-pile
/// rather than left implicit.
///
/// The owner's third report: "the voice canvas feels like its missing life
/// from it." Written when a camera bubble only existed while somebody's
/// camera was on, and only for whoever this device had already subscribed
/// to - most of a real conversation showed nothing here at all. Since
/// decision 0010, that premise is gone: every call participant now has a
/// standing tile on the canvas (`CanvasPresenceLayer`), camera on or off, so
/// this widget's own job narrowed to the one case a tile still cannot
/// cover - somebody reading the board with a live cursor but on no call
/// here at all. Naming a call participant a second time, in a small avatar
/// stacked beside their own full tile, is not "more life," it is the same
/// person counted twice.
///
/// This closes that narrower gap honestly rather than by inventing a signal
/// the wire does not carry. There is no "has this canvas open" event from
/// the server (see this file's own knowledge-base entry for why one would
/// need a real server change, left for the owner rather than faked here) -
/// only whose cursor has moved recently enough that [CanvasCursors] has not
/// pruned it, for somebody this device did not already give a tile.
///
/// Membership changes swap instantly, deliberately not cross-faded: a new
/// face appearing already carries the meaning on its own, and animating the
/// swap on top of that would be motion for its own sake rather than motion
/// that says anything a plain appearance does not already say.
///
/// **A known boundary, not a bug: somebody with the canvas open, on no call
/// here, and not moving a pointer is invisible here.** Silently reading a
/// shared board is a real, common thing to do, and there is genuinely no
/// wire signal for it - "has this canvas open" is not an event the server
/// sends, and inventing one client-side would be exactly the fabrication
/// this file's own opening paragraph already rejected. So a quiet reader
/// reads as absent; closing it needs a real server change, left for the
/// owner.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../widgets/user_avatar.dart';

/// One entry in the face-pile: a name, an id to key the avatar's colour and
/// its animation identity, and a stable sort key.
class _Present {
  const _Present({required this.id, required this.name});

  final String id;
  final String name;
}

/// Positioned top-right - the error/truncation banners already
/// claim the top-left-to-center band, and the floating dock owns the bottom.
/// [IgnorePointer]-wrapped throughout, the same treatment `CanvasPresenceLayer`
/// already gives camera bubbles: this is presence chrome, never a drawing
/// target.
///
/// **There is no tie-break against the self camera bubble any more.**
/// Before decision 0010's media-tile work the self bubble was a
/// screen-anchored overlay with its own resting corner, and this class used
/// to watch it and swap to top-left when the two would collide. The self
/// bubble is a world-anchored, freely draggable tile now, like every other
/// camera or screen-share tile, so it has no screen corner of its own left
/// to collide with, and the corner is fixed. What a world-anchored tile *can* still do is pan underneath this
/// fixed corner, controls included; that residual is recorded, not solved,
/// in decision 0010's own "What was left" section.
class CanvasPresenceRoster extends StatefulWidget {
  const CanvasPresenceRoster({
    super.key,
    required this.callParticipants,
    this.cursors,
  });

  /// Read only to exclude anyone already on this channel's call from
  /// [_present] - see that method's own doc for why - not filtered for
  /// blocking here, since a blocked call participant is excluded by this
  /// same check regardless of the reason. [cursors] is filtered upstream by
  /// `CanvasCursorRelay.applyRemote`, the same "filter before it reaches
  /// this widget" shape every other presence surface on this canvas
  /// follows.
  final List<VoiceParticipant> callParticipants;
  final CanvasCursors? cursors;

  @override
  State<CanvasPresenceRoster> createState() => _CanvasPresenceRosterState();
}

class _CanvasPresenceRosterState extends State<CanvasPresenceRoster> {
  @override
  void initState() {
    super.initState();
    widget.cursors?.addListener(_onCursorsChanged);
  }

  @override
  void didUpdateWidget(covariant CanvasPresenceRoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cursors != widget.cursors) {
      oldWidget.cursors?.removeListener(_onCursorsChanged);
      widget.cursors?.addListener(_onCursorsChanged);
    }
  }

  @override
  void dispose() {
    widget.cursors?.removeListener(_onCursorsChanged);
    super.dispose();
  }

  void _onCursorsChanged() {
    if (mounted) setState(() {});
  }

  /// Cursor-only presence: somebody moving a pointer on this canvas who is
  /// not on this channel's call. A call participant - this device's own
  /// included - is never listed here, whatever their cursor is doing:
  /// `CanvasPresenceLayer` already gives every one of them a standing tile,
  /// camera on or off, so naming them again in this small face-pile would
  /// be the same person counted twice rather than "more life" on a quiet
  /// board - the redundancy decision 0010 names once every call participant
  /// became a real tile.
  List<_Present> _present() {
    final onCall = <String>{
      for (final p in widget.callParticipants) p.identity,
    };
    final byId = <String, _Present>{};
    for (final cursor in widget.cursors?.all ?? const <CanvasCursor>[]) {
      if (onCall.contains(cursor.id)) continue;
      byId[cursor.id] = _Present(id: cursor.id, name: cursor.label);
    }
    final present = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return present;
  }

  @override
  Widget build(BuildContext context) {
    final present = _present();
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        minimum: const EdgeInsets.all(AppSpacing.s12),
        child: IgnorePointer(
          child: present.isEmpty
              ? const SizedBox.shrink()
              : _FacePile(present: present),
        ),
      ),
    );
  }
}

class _FacePile extends StatelessWidget {
  const _FacePile({required this.present});

  final List<_Present> present;

  static const int _maxShown = 4;
  static const double _avatarSize = AppAvatarSize.s24;
  static const double _overlap = 8;

  /// The horizontal distance from one avatar's left edge to the next -
  /// [_avatarSize] minus how much the next one overlaps this one.
  static const double _stride = _avatarSize - _overlap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final shown = present.take(_maxShown).toList();
    final overflow = present.length - shown.length;
    // Positioned in an explicit Stack, not negative Padding, which asserts non-negative.
    final stackWidth = shown.isEmpty
        ? 0.0
        : _avatarSize + (shown.length - 1) * _stride;
    final label = 'On this canvas: ${present.map((p) => p.name).join(', ')}';
    return Semantics(
      container: true,
      label: label,
      // excludeFromSemantics avoids doubling the Semantics label above for assistive tech.
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.s4),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadii.full),
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: stackWidth,
                  height: _avatarSize,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < shown.length; i++)
                        Positioned(
                          left: i * _stride,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: tokens.surfaceRaised,
                                width: 2,
                              ),
                            ),
                            child: UserAvatar(
                              name: shown[i].name,
                              userId: shown[i].id,
                              size: _avatarSize,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (overflow > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s4,
                    ),
                    child: Text(
                      '+$overflow',
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                        fontWeight: AppWeights.medium,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
