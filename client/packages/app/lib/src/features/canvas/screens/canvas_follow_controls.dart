// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Follow someone's view, or bring everyone to yours.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

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

class CanvasFollowControls extends StatelessWidget {
  const CanvasFollowControls({
    super.key,
    required this.relay,
    required this.cursors,
    required this.participants,
    required this.selfId,
    required this.onBringEveryone,
  });

  final CanvasViewRelay relay;
  final CanvasCursors cursors;
  final List<VoiceParticipant> participants;
  final String? selfId;
  final VoidCallback onBringEveryone;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Align(
      alignment: Alignment.topRight,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          AppSpacing.s12,
          AppSpacing.s48,
          AppSpacing.s12,
          AppSpacing.s12,
        ),
        child: ListenableBuilder(
          listenable: Listenable.merge([cursors, relay.following]),
          builder: (context, _) {
            final targets = canvasFollowTargets(
              cursors: cursors.all,
              participants: participants,
              selfId: selfId,
            );
            final followed = relay.following.value;
            if (targets.isEmpty && followed == null) {
              return const SizedBox.shrink();
            }
            return _Panel(
              tokens: tokens,
              targets: targets,
              followed: followed,
              relay: relay,
              onBringEveryone: onBringEveryone,
            );
          },
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
  final VoidCallback onBringEveryone;

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
          for (final target in targets)
            _PersonButton(
              target: target,
              selected: target.id == followed,
              tokens: tokens,
              onTap: () => target.id == followed
                  ? relay.stopFollowing()
                  : relay.follow(target.id),
            ),
          if (following != null)
            AppIconButton(
              icon: AppIcons.dismiss,
              semanticLabel: 'Stop following ${following.name}',
              tooltip: 'Stop following ${following.name}',
              onPressed: relay.stopFollowing,
            ),
          AppIconButton(
            icon: AppIcons.recenter,
            semanticLabel: 'Bring everyone to me',
            tooltip: 'Bring everyone to me',
            onPressed: onBringEveryone,
          ),
        ],
      ),
    );
  }
}

class _PersonButton extends StatelessWidget {
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
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: selected
        ? 'Following ${target.name}, tap to stop'
        : 'Follow ${target.name}',
    excludeSemantics: true,
    onTap: onTap,
    child: Tooltip(
      message: selected
          ? 'Stop following ${target.name}'
          : 'Follow ${target.name}',
      child: InkResponse(
        onTap: onTap,
        radius: AppSpacing.s24,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? tokens.accentFill : Colors.transparent,
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
  );
}
