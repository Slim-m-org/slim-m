// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two overlapping avatars standing for a group DM's other participants.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';
import '../../members/widgets/user_avatar.dart';

/// The first two of [memberIds] on a diagonal inside a [size] square, so a
/// group reads as several people at a glance. One member alone is drawn as
/// that person's avatar, the shape a pair already uses.
class GroupAvatarStack extends ConsumerWidget {
  const GroupAvatarStack({
    super.key,
    required this.memberIds,
    this.size = AppAvatarSize.s28,
    this.badge,
  });

  /// The other participants, never the caller.
  final List<String> memberIds;
  final double size;

  /// Drawn in the stack's dot slot, for a group nobody is left in.
  final AppAvatarBadge? badge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (memberIds.length < 2) {
      return _Face(userId: memberIds.firstOrNull, size: size, badge: badge);
    }
    const ring = 1.0;
    final face = size <= AppAvatarSize.s28
        ? AppAvatarSize.s16
        : AppAvatarSize.s24;
    final stack = SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: _Face(userId: memberIds[0], size: face),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(ring),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.surfaceBase,
              ),
              child: _Face(userId: memberIds[1], size: face),
            ),
          ),
        ],
      ),
    );
    final marked = badge == null
        ? stack
        : AppAvatarMarkSlot(
            geometry: AppAvatarGeometry(size, badge: true),
            mark: AppAvatarBadgeMark(
              badge: badge!,
              size: AppAvatarGeometry(size, badge: true).markDiameter,
            ),
            child: stack,
          );
    return Semantics(
      label:
          '${memberIds.length + 1} people'
          '${badge == null ? '' : ', ${badge!.word}'}',
      excludeSemantics: true,
      child: marked,
    );
  }
}

class _Face extends ConsumerWidget {
  const _Face({required this.userId, required this.size, this.badge});

  final String? userId;
  final double size;
  final AppAvatarBadge? badge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = userId;
    final name = id == null
        ? ''
        : ref.watch(userProfileProvider(id)).valueOrNull?.displayName ?? '';
    return UserAvatar(name: name, userId: id, size: size, badge: badge);
  }
}
