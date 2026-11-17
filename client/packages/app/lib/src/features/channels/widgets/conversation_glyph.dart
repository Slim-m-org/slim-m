// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picture standing for a DM or group DM in a list that mixes them with
/// channels (the inbox, the home): the person's avatar or the group's stack.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart' show sessionProvider;
import '../../members/widgets/user_avatar.dart';
import '../providers/dms.dart' show dmChannelKind;
import 'group_avatar_stack.dart';

class ConversationGlyph extends ConsumerWidget {
  const ConversationGlyph({
    super.key,
    required this.channel,
    required this.size,
    required this.fallback,
  });

  final Channel channel;
  final double size;

  /// What a channel, and the personal space, draws instead of an avatar.
  final Widget fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox.square(
    dimension: size,
    child: Center(child: _glyph(ref)),
  );

  Widget _glyph(WidgetRef ref) {
    if (channel.kind != dmChannelKind || channel.isPersonalSpace) {
      return fallback;
    }
    if (channel.isGroupDm) {
      final self = ref.watch(sessionProvider).tokens?.userId;
      return GroupAvatarStack(
        memberIds: [
          for (final id in channel.groupMemberIds)
            if (id != self) id,
        ],
        size: size,
      );
    }
    return UserAvatar(
      name: channel.name,
      userId: channel.dmParticipantId,
      size: size,
    );
  }
}
