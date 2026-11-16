// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An administrator renaming somebody else's account inside this Space
/// (`PUT`/`DELETE /members/{userId}/nickname`, decision 0055).
///
/// A nickname is what every reader sees; the account's own name stays what the
/// account chose and is still shown to them in their own profile. So this sheet
/// says so, and offers to remove the nickname as readily as to set one. Length
/// is checked here so the button disables before a doomed request; the
/// character rule is left to the server, as in `edit_display_name_sheet.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_presence.dart' show membersProvider;
import '../../../widgets/name_sheet.dart';
import '../providers/member_actions.dart';

Future<void> showRenameMemberSheet(
  BuildContext context, {
  required api.UserProfile profile,
}) {
  final accountName = profile.accountDisplayName ?? profile.displayName;
  return showNameSheet(
    context,
    title: 'Rename ${profile.displayName}',
    caption:
        'Everyone in this Space sees this name. Their own name, '
        '$accountName, stays in their profile and is not changed.',
    fieldLabel: 'Nickname',
    placeholder: accountName,
    initial: profile.nickname ?? '',
    maxChars: api.InputLimits.name,
    whatFailed: 'rename ${profile.displayName}',
    onSave: (ref, name) async {
      await ref
          .read(memberActionsProvider)
          .setMemberNickname(userId: profile.id, nickname: name);
      ref.invalidate(membersProvider);
    },
    secondary: profile.nickname == null
        ? null
        : NameSheetAction(
            label: 'Remove nickname',
            whatFailed: 'remove the nickname',
            run: (ref) async {
              await ref
                  .read(memberActionsProvider)
                  .clearMemberNickname(profile.id);
              ref.invalidate(membersProvider);
            },
          ),
  );
}

/// The Moderate sub-view's row for [showRenameMemberSheet].
class RenameMemberMenuItem extends StatelessWidget {
  const RenameMemberMenuItem({
    super.key,
    required this.host,
    required this.profile,
    required this.onDone,
  });

  /// A context that outlives the popover; see `member_profile.dart`'s `host`.
  final BuildContext host;
  final api.UserProfile profile;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => AppMenuItem(
    label: 'Rename...',
    leading: AppIcons.edit,
    submenu: true,
    onTap: () {
      onDone();
      unawaited(showRenameMemberSheet(host, profile: profile));
    },
  );
}
