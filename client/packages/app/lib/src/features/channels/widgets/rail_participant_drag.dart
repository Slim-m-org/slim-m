// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dragging a person from one voice channel onto another in the rail, for
/// anyone who may move members. Pointer only: a finger scrolls the rail, and
/// the participant menu's "Move to..." row is the touch route.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart' show myPermissionsProvider;
import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';

/// Who is being carried, and from where.
class ParticipantDragData {
  const ParticipantDragData({
    required this.userId,
    required this.name,
    required this.fromChannelId,
  });

  final String userId;
  final String name;
  final String fromChannelId;
}

/// The last drop that the server refused, shown over the rail until dismissed.
final railMoveFailureProvider = StateProvider<String?>((ref) => null);

/// Moves [data]'s person to [toChannelId], recording a refusal for the rail.
Future<void> moveByDrag(
  WidgetRef ref,
  ParticipantDragData data,
  String toChannelId,
) async {
  ref.read(railMoveFailureProvider.notifier).state = null;
  final failure = await runGuarded(
    whatFailed: 'move ${data.name}',
    action: () => ref
        .read(apiProvider)
        .moveVoiceParticipant(data.fromChannelId, data.userId, toChannelId),
  );
  if (failure != null) {
    ref.read(railMoveFailureProvider.notifier).state = failure;
  }
}

/// Makes [child] draggable with a mouse when the viewer may move members.
class RailParticipantDraggable extends ConsumerStatefulWidget {
  const RailParticipantDraggable({
    super.key,
    required this.data,
    required this.child,
  });

  final ParticipantDragData data;
  final Widget child;

  @override
  ConsumerState<RailParticipantDraggable> createState() =>
      _RailParticipantDraggableState();
}

class _RailParticipantDraggableState
    extends ConsumerState<RailParticipantDraggable> {
  bool _mouse = false;

  @override
  Widget build(BuildContext context) {
    final canMove = ref.watch(
      myPermissionsProvider.select((p) => p.hasPermission(Perm.moveMembers)),
    );
    if (!canMove) return widget.child;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Hover precedes the press, which is the only time a pointer's kind is known before the drag recognizer is built.
    return MouseRegion(
      onEnter: (_) => setState(() => _mouse = true),
      onExit: (_) => setState(() => _mouse = false),
      child: Draggable<ParticipantDragData>(
        data: widget.data,
        maxSimultaneousDrags: _mouse ? 1 : 0,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s12,
              vertical: AppSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              border: Border.all(color: tokens.borderStrong),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Text(
              widget.data.name,
              style: AppText.caption.copyWith(color: tokens.textPrimary),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: widget.child),
        child: widget.child,
      ),
    );
  }
}

/// Accepts a dragged participant onto a voice channel row.
class RailMoveDropTarget extends ConsumerWidget {
  const RailMoveDropTarget({
    super.key,
    required this.channelId,
    required this.child,
  });

  final String channelId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DragTarget<ParticipantDragData>(
      onWillAcceptWithDetails: (d) => d.data.fromChannelId != channelId,
      onAcceptWithDetails: (d) => unawaited(moveByDrag(ref, d.data, channelId)),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: candidates.isEmpty ? null : Border.all(color: tokens.accent),
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: child,
      ),
    );
  }
}
