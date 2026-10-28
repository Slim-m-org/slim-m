// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picture before a conversation's name in its header, wide or compact.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/providers.dart' show sessionProvider;
import 'channel_kind_icon.dart';
import 'group_avatar_stack.dart';
import '../../members/widgets/user_avatar.dart';

/// A DM is a person, so it shows their avatar and presence like every other
/// surface naming one; the personal space keeps its notebook, and a text or
/// voice channel its own icon.
class ChannelTitleGlyph extends StatelessWidget {
  const ChannelTitleGlyph({
    super.key,
    required this.name,
    required this.isVoice,
    required this.restricted,
    required this.isDm,
    required this.isPersonalSpace,
    required this.dmParticipantId,
    this.groupMemberIds = const [],
  });

  final String name;
  final bool isVoice;
  final bool restricted;
  final bool isDm;
  final bool isPersonalSpace;
  final String? dmParticipantId;

  /// Every participant of a group DM, the caller included.
  final List<String> groupMemberIds;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (isPersonalSpace) {
      return Icon(
        AppIcons.notebook,
        size: AppSizes.icon16,
        color: tokens.textSecondary,
      );
    }
    if (groupMemberIds.isNotEmpty) {
      return Consumer(
        builder: (context, ref, _) => GroupAvatarStack(
          memberIds: [
            for (final id in groupMemberIds)
              if (id != ref.watch(sessionProvider).tokens?.userId) id,
          ],
          size: AppAvatarSize.s28,
        ),
      );
    }
    if (isDm) {
      return UserAvatar(
        name: name,
        userId: dmParticipantId,
        size: AppAvatarSize.s24,
        presence: true,
      );
    }
    return ChannelKindIcon(
      isVoice: isVoice,
      restricted: restricted,
      color: tokens.textSecondary,
    );
  }
}
