// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Account recovery: issuing a member a one-time password reset code.
///
/// The action itself already shipped, on a member's profile popover. Nothing
/// in Space settings mentioned recovery at all, so an administrator looking
/// for it there - which is where an admin action is expected to live - found
/// nothing and concluded the feature was missing. This is a second way in, not
/// a move: [ResetCodeMenuItem] on the popover still works and is still the
/// fastest route when you already have the person in front of you.
///
/// Requires ADMINISTRATOR, matching `POST /admin/users/{id}/reset-code`, which
/// refuses anything less. Issuing a code is a way into somebody else's account, so it
/// asks for more than the MANAGE_SERVER that gates most of Space settings.
///
/// Without the bit the action is absent rather than disabled, which is the
/// rule `space_settings_section.dart`'s own gate states: a member should not
/// be shown a surface and left to answer 403. `removed_members_screen.dart`
/// hides its ADMINISTRATOR-only delete the same way. That state is reachable
/// only by typing the route, since Space settings does not list this pane
/// otherwise, and it still says why it is empty rather than going blank.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'package:slimm_api/api.dart' as api;

import '../../permissions.dart';
import '../../providers/admin_providers.dart';
import '../../routing/routes.dart';
import '../../widgets/reset_code_sheet.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'overwrite_target_picker_sheets.dart';
import '../../action_labels.dart';

const resetCodesDescription =
    'Locked-out members get back in with an administrator\'s one-time code.';

class AccountRecoveryScreen extends StatelessWidget {
  const AccountRecoveryScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Account recovery',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: AccountRecoveryPane(),
  );
}

/// The recovery explanation and its one action, embeddable as a Space settings
/// pane as well as routed.
class AccountRecoveryPane extends ConsumerWidget {
  const AccountRecoveryPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canIssue = ref
        .watch(myPermissionsProvider)
        .hasPermission(Perm.administrator);

    // Hidden, not inert: see this library's doc for the rule.
    if (!canIssue) {
      return const SettingsSectionCard(
        flush: true,
        children: [
          SettingsEmptyState(
            icon: AppIcons.shield,
            title: 'Issuing a reset code needs the administrator permission.',
            detail: 'Locked-out members get back in with a one-time code.',
          ),
        ],
      );
    }

    return SettingsSectionCard(
      flush: true,
      title: 'Reset codes',
      description: resetCodesDescription,
      children: [
        SettingsDetailRow(
          icon: AppIcons.resetCode,
          title: 'Password reset code',
          detail: 'Pick a member, confirm your password, hand them the code.',
          trailing: AppButton(
            label: ActionLabels.createResetCode,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: () => _pickThenIssue(context),
          ),
        ),
      ],
    );
  }
}

/// Chooses a member, then opens the issuing sheet for them.
///
/// Two sheets rather than one screen: the picker and the issuing sheet both
/// already exist and neither knows about the other, so this is the whole of
/// the new path. A cancelled pick closes without issuing anything.
Future<void> _pickThenIssue(BuildContext context) async {
  final member = await showAppSheet<api.UserProfile>(
    context,
    builder: (context) => const MemberPickerSheet(),
  );
  if (member == null || !context.mounted) return;
  await showResetCodeSheet(
    context,
    subjectId: member.id,
    subjectName: member.displayName,
  );
}
