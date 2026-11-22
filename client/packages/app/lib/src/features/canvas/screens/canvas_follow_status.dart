// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What following someone looks like on the canvas: an outline around the view in their colour, and a chip that names them and stops it.
/// It also lets go of a followed person who left, so their return cannot pull the camera.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../widgets/canvas_pill_surface.dart';
import 'canvas_follow_targets.dart';
import 'canvas_people_session.dart';

/// The width of the outline; wide enough to read as a state, thin enough to cover no ink.
const double canvasFollowOutlineWidth = 3;

/// The outline over the board; it also lets go of a followed person who left.
class CanvasFollowOutline extends StatelessWidget {
  const CanvasFollowOutline({super.key, required this.participants});

  /// The call, so a follow of someone with no cursor still resolves to a name.
  final List<VoiceParticipant> participants;

  @override
  Widget build(BuildContext context) {
    final following = _resolveFollowing(context, participants);
    if (following == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: DecoratedBox(
        key: followOutlineKey,
        decoration: BoxDecoration(
          border: Border.all(
            color: following.color,
            width: canvasFollowOutlineWidth,
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// The chip and the summon card as a strip of the pane's own chrome, above the board so neither covers a tile.
class CanvasFollowStrip extends StatelessWidget {
  const CanvasFollowStrip({
    super.key,
    required this.participants,
    required this.below,
  });

  final List<VoiceParticipant> participants;

  /// Shown under the chip in the same strip, so the two never overlap.
  final Widget below;

  @override
  Widget build(BuildContext context) {
    final following = _resolveFollowing(context, participants);
    final session = CanvasPeopleScope.maybeOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (following != null && session != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: _Chip(
                name: following.name,
                color: following.color,
                tokens: Theme.of(context).extension<AppTokens>()!,
                onStop: session.stopFollowing,
              ),
            ),
          below,
        ],
      ),
    );
  }
}

typedef _Following = ({String name, Color color});

_Following? _resolveFollowing(
  BuildContext context,
  List<VoiceParticipant> participants,
) {
  final session = CanvasPeopleScope.maybeOf(context);
  if (session == null) return null;
  final targets = canvasFollowTargets(
    cursors: session.cursors.all,
    participants: participants,
    selfId: session.selfId(),
  );
  final followed = targets.where((t) => t.id == session.followed).firstOrNull;
  if (followed == null) {
    _dropFollowedWhoLeft(context, session);
    return null;
  }
  final tokens = Theme.of(context).extension<AppTokens>()!;
  return (
    name: followed.name,
    color: session.followedColor ?? tokens.accentFill,
  );
}

// Someone who left can no longer be followed, so their return must not pull the camera.
void _dropFollowedWhoLeft(BuildContext context, CanvasPeopleSession session) {
  final followed = session.followed;
  if (followed == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) session.relay.forget(followed);
  });
}

const followOutlineKey = ValueKey('canvas-follow-outline');

class _Chip extends StatelessWidget {
  const _Chip({
    required this.name,
    required this.color,
    required this.tokens,
    required this.onStop,
  });

  final String name;
  final Color color;
  final AppTokens tokens;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    liveRegion: true,
    label: 'Following $name',
    child: Tooltip(
      message: 'Stop following $name',
      child: CanvasPillSurface(
        tokens: tokens,
        onTap: onStop,
        borderColor: color,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.icon28),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    'Following $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.medium,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Icon(
                  AppIcons.dismiss,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
