// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Follow someone's view, or bring everyone to yours.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/confirm_dialog.dart';
import '../../members/widgets/user_avatar.dart';
import 'canvas_view_relay.dart';

/// One person who can be followed.
class CanvasFollowTarget {
  const CanvasFollowTarget(this.id, this.name);

  final String id;
  final String name;
}

/// Everyone else on the canvas or its call, one entry each, in a stable order.
List<CanvasFollowTarget> canvasFollowTargets({
  required Iterable<CanvasCursor> cursors,
  required Iterable<VoiceParticipant> participants,
  required String? selfId,
}) {
  final byId = <String, CanvasFollowTarget>{
    for (final c in cursors) c.id: CanvasFollowTarget(c.id, c.label),
    for (final p in participants)
      if (!p.isLocal) p.identity: CanvasFollowTarget(p.identity, p.name),
  }..remove(selfId);
  return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
}

/// Clears the top-left corner's rows: two rows of 44 at touch size, two of 28 otherwise.
double _topInset(BuildContext context) => AppTouchTargets.of(context)
    ? AppSpacing.s12 + 2 * AppSizes.rowTouch + 2 * AppSpacing.s8
    : AppSpacing.s64;

class CanvasFollowControls extends StatefulWidget {
  const CanvasFollowControls({
    super.key,
    required this.relay,
    required this.cursors,
    required this.participants,
    required this.selfId,
    required this.onBringEveryone,
    this.canBringEveryone = true,
  });

  final CanvasViewRelay relay;
  final CanvasCursors cursors;
  final List<VoiceParticipant> participants;
  final String? selfId;
  final VoidCallback onBringEveryone;

  /// False in the personal view, whose camera is never relayed (decision 0082).
  final bool canBringEveryone;

  @override
  State<CanvasFollowControls> createState() => _CanvasFollowControlsState();
}

class _CanvasFollowControlsState extends State<CanvasFollowControls> {
  List<CanvasFollowTarget> _targets = const [];
  String? _followed;

  @override
  void initState() {
    super.initState();
    widget.cursors.addListener(_refresh);
    widget.relay.following.addListener(_refresh);
    _targets = _compute();
    _followed = widget.relay.following.value;
  }

  @override
  void didUpdateWidget(covariant CanvasFollowControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cursors != widget.cursors) {
      oldWidget.cursors.removeListener(_refresh);
      widget.cursors.addListener(_refresh);
    }
    if (oldWidget.relay != widget.relay) {
      oldWidget.relay.following.removeListener(_refresh);
      widget.relay.following.addListener(_refresh);
    }
    _refresh(force: true);
  }

  @override
  void dispose() {
    widget.cursors.removeListener(_refresh);
    widget.relay.following.removeListener(_refresh);
    super.dispose();
  }

  List<CanvasFollowTarget> _compute() => canvasFollowTargets(
    cursors: widget.cursors.all,
    participants: widget.participants,
    selfId: widget.selfId,
  );

  // Cursor frames arrive at pointer rate; only who can be followed matters here.
  void _refresh({bool force = false}) {
    if (!mounted) return;
    final targets = _compute();
    final followed = widget.relay.following.value;
    final same =
        followed == _followed &&
        targets.length == _targets.length &&
        [for (var i = 0; i < targets.length; i++) i].every(
          (i) =>
              targets[i].id == _targets[i].id &&
              targets[i].name == _targets[i].name,
        );
    if (same && !force) return;
    setState(() {
      _targets = targets;
      _followed = followed;
    });
  }

  // Someone who left can no longer be followed, so their return must not pull the camera.
  void _dropFollowedWhoLeft() {
    final followed = _followed;
    if (followed == null || _targets.any((t) => t.id == followed)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.relay.forget(followed);
    });
  }

  Future<void> _confirmBringEveryone() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Bring everyone to you?',
      message:
          'Every viewer jumps to the part of the board you are looking at.',
      confirmLabel: 'Bring everyone',
    );
    if (confirmed) widget.onBringEveryone();
  }

  @override
  Widget build(BuildContext context) {
    _dropFollowedWhoLeft();
    final followed = _followed;
    if (_targets.isEmpty && followed == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        minimum: EdgeInsets.fromLTRB(
          AppSpacing.s12,
          _topInset(context),
          AppSpacing.s12,
          AppSpacing.s12,
        ),
        child: _Panel(
          tokens: tokens,
          targets: _targets,
          followed: followed,
          relay: widget.relay,
          onBringEveryone: widget.canBringEveryone
              ? () => unawaited(_confirmBringEveryone())
              : null,
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.tokens,
    required this.targets,
    required this.followed,
    required this.relay,
    required this.onBringEveryone,
  });

  final AppTokens tokens;
  final List<CanvasFollowTarget> targets;
  final String? followed;
  final CanvasViewRelay relay;
  final VoidCallback? onBringEveryone;

  @override
  Widget build(BuildContext context) {
    final following = targets.where((t) => t.id == followed).firstOrNull;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.full),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Scrolls rather than overflowing, so the buttons after it stay on screen in a big call.
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final target in targets)
                    _PersonButton(
                      target: target,
                      selected: target.id == followed,
                      tokens: tokens,
                      onTap: () => target.id == followed
                          ? relay.stopFollowing()
                          : relay.follow(target.id),
                    ),
                ],
              ),
            ),
          ),
          if (followed != null)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: following == null
                  ? 'Stop following'
                  : 'Stop following ${following.name}',
              tooltip: following == null
                  ? 'Stop following'
                  : 'Stop following ${following.name}',
              onPressed: relay.stopFollowing,
            ),
          if (onBringEveryone != null)
            AppIconButton(
              icon: AppIcons.members,
              semanticLabel: 'Bring everyone to me',
              tooltip: 'Bring everyone to me',
              onPressed: onBringEveryone,
            ),
        ],
      ),
    );
  }
}

class _PersonButton extends StatefulWidget {
  const _PersonButton({
    required this.target,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final CanvasFollowTarget target;
  final bool selected;
  final AppTokens tokens;
  final VoidCallback onTap;

  @override
  State<_PersonButton> createState() => _PersonButtonState();
}

class _PersonButtonState extends State<_PersonButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final selected = widget.selected;
    final tokens = widget.tokens;
    final touch = AppTouchTargets.of(context);
    // Layout room around the 32 square, so its hit area reaches a full 44 at touch density.
    return Padding(
      padding: EdgeInsets.all(touch ? (AppSizes.rowTouch - 32) / 2 : 0),
      child: AppTouchHitArea(
        child: Semantics(
          button: true,
          selected: selected,
          label: selected
              ? 'Following ${target.name}, tap to stop'
              : 'Follow ${target.name}',
          excludeSemantics: true,
          onTap: widget.onTap,
          child: Tooltip(
            message: selected
                ? 'Stop following ${target.name}'
                : 'Follow ${target.name}',
            child: InkResponse(
              onTap: widget.onTap,
              onFocusChange: (focused) => setState(() => _focused = focused),
              radius: AppSpacing.s24,
              // An outer ring, not a recolour: focusRing and accentFill are the same colour, and selection owns the inner ring.
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _focused ? tokens.focusRing : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? tokens.accentFill
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: UserAvatar(
                        name: target.name,
                        userId: target.id,
                        size: AppAvatarSize.s24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
