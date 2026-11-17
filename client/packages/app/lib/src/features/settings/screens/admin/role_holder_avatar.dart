// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The avatar a role surface draws for a member: round for a person, square
/// with the bot placeholder for a bot.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../members/widgets/bot_avatar_placeholder.dart';
import '../../../members/widgets/profile_colour.dart';
import '../../../members/widgets/user_avatar.dart';

Widget roleHolderAvatar(
  BuildContext context,
  api.UserProfile member, {
  double size = AppAvatarSize.s28,
}) => UserAvatar.known(
  name: member.displayName,
  userId: member.id,
  avatarUpdatedAt: member.avatarUpdatedAt,
  profileColour: profileColourOfUser(member),
  size: size,
  shape: member.isBot ? AppAvatarShape.square : AppAvatarShape.circle,
  placeholder: member.isBot
      ? botAvatarPlaceholder(context, member.displayName)
      : null,
);
