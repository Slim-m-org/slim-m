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

class CanvasFollowStatus extends StatefulWidget {
  const CanvasFollowStatus({
    super.key,
    required this.participants,
    required this.below,
  });

  /// The call, so a follow of someone with no cursor still resolves to a name.
  final List<VoiceParticipant> participants;

  /// Shown under the chip in the same top-centre slot, so the two never overlap.
  final Widget below;

  @override
  State<CanvasFollowStatus> createState() => _CanvasFollowStatusState();
}

class _CanvasFollowStatusState extends State<CanvasFollowStatus> {
  // Someone who left can no longer be followed, so their return must not pull the camera.
  void _dropFollowedWhoLeft(
    CanvasPeopleSession session,
    List<CanvasFollowTarget> targets,
  ) {
    final followed = session.followed;
    if (followed == null || targets.any((t) => t.id == followed)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) session.relay.forget(followed);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = CanvasPeopleScope.maybeOf(context);
    if (session == null) return _slot(context, null);
    final targets = canvasFollowTargets(
      cursors: session.cursors.all,
      participants: widget.participants,
      selfId: session.selfId(),
    );
    _dropFollowedWhoLeft(session, targets);
    final followed = targets.where((t) => t.id == session.followed).firstOrNull;
    if (followed == null) return _slot(context, null);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final color = session.followedColor ?? tokens.accentFill;
    return _slot(context, (
      color: color,
      chip: _Chip(
        name: followed.name,
        color: color,
        tokens: tokens,
        onStop: session.stopFollowing,
      ),
    ));
  }

  Widget _slot(BuildContext context, ({Color color, Widget chip})? following) =>
      Stack(
        fit: StackFit.expand,
        children: [
          if (following != null)
            IgnorePointer(
              child: DecoratedBox(
                key: followOutlineKey,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: following.color,
                    width: canvasFollowOutlineWidth,
                  ),
                ),
              ),
            ),
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              minimum: EdgeInsets.fromLTRB(
                AppSpacing.s12,
                canvasCornerRowsInset(context),
                AppSpacing.s12,
                AppSpacing.s12,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?following?.chip,
                  if (following != null) const SizedBox(height: AppSpacing.s8),
                  widget.below,
                ],
              ),
            ),
          ),
        ],
      );
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
