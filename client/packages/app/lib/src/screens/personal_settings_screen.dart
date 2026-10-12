// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Personal settings: what the account holder controls about themselves,
/// plus the app's own build information.
///
/// This is the one settings screen every signed-in caller can always reach,
/// regardless of permission; [SpaceSettingsScreen] is the deployment-level
/// counterpart, reached separately from the rail's Space menu and hidden
/// entirely for a caller holding none of its gating bits.
///
/// Nine sections used to sit in one scroll behind full-width dividers. They
/// are five panes now; see [SettingsPanesScaffold] for why, and note the
/// grouping rather than the count is the point: what you are, what a call
/// does, and who you have shut out are three different questions.
///
/// Voice is folded in here rather than living on its own screen, so mic level,
/// sensitivity, push-to-talk and share quality sit beside the account they
/// belong to instead of behind a second route nothing linked to twice.
///
/// **Two headings over seven panes, not four.** `Calls` held one pane and
/// `About` held one, so the nav alternated heading, row, heading, row down
/// its whole length - a heading roughly as often as a thing to click, which
/// is what made the list read as choppy rather than grouped.
///
/// Voice sits under `You` now, where a personal microphone and share-quality
/// preference always belonged. `About slim-m` keeps its own run but drops the
/// heading entirely: it is one pane, and naming a group of one is decoration.
/// A heading here always marks more than one pane, which
/// `settings_taxonomy_test.dart` holds as a rule rather than a habit.
///
/// `Delete account` moved with it, out of the pane labelled `About slim-m`
/// and into `Account & devices`. It is permanent and irreversible, and it
/// was reached by opening a pane whose name promises a version number. About
/// is the app's own build information now and nothing else.
///
/// Who you are, and the rename affordance for it, used to float above the nav
/// as its own unlabelled block - editable, yet outside every named section,
/// so "rename yourself" read as belonging to nothing. It lives inside
/// [AvatarSettingsSection]'s own "Profile" card, which is its own pane now:
/// `Account & profile` used to also hold devices, app lock and account
/// deletion in the same scroll, four unrelated questions (who you are, what
/// signs in as you, whether opening this app needs a passcode, and how to
/// leave) stacked under one name. `Profile` is who you are; `Account &
/// devices` is everything about the account and what signs into it. Each
/// pane in the nav carries a leading icon the way [SpaceSettingsSection]'s
/// rows already do.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../routing/routes.dart';
import '../widgets/activity_sharing_section.dart';
import '../widgets/app_info_section.dart';
import '../widgets/app_lock_section.dart';
import '../widgets/appearance_settings_section.dart';
import '../widgets/performance_settings_section.dart';
import '../widgets/avatar_settings_section.dart';
import '../widgets/personal_account_sections.dart';
import '../widgets/personal_status_sections.dart';
import '../widgets/profile_fields_section.dart';
import '../widgets/report_status_section.dart';
import '../widgets/settings_panes.dart';
import '../widgets/settings_profile_preview.dart';
import '../widgets/totp_section.dart';
import '../widgets/change_password_section.dart';
import 'voice_settings_screen.dart';
import '../action_labels.dart';

class PersonalSettingsScreen extends StatelessWidget {
  const PersonalSettingsScreen({
    super.key,
    this.initialPaneId,
    this.onPaneChanged,
  });

  /// The pane to open on, when something deep-links to one.
  final String? initialPaneId;

  /// See [SettingsPanesScaffold.onPaneChanged].
  final ValueChanged<String?>? onPaneChanged;

  @override
  Widget build(BuildContext context) {
    return SettingsPanesScaffold(
      initialPaneId: initialPaneId,
      onPaneChanged: onPaneChanged,
      title: 'Settings',
      // Reached with go(), which replaces, so there is no stack to pop.
      backTooltip: 'Back to channels',
      backFallback: Routes.channels,
      footer: const SignOutRow(),
      groups: [
        SettingsPaneGroup(
          label: 'You',
          panes: [
            SettingsPane(
              id: 'profile',
              label: 'Profile',
              icon: AppIcons.account,
              // No presence rows: the rail footer's own status menu already sets both the state and the status text.
              builder: (context) => const Column(
                children: [
                  AvatarSettingsSection(),
                  ProfileFieldsSection(),
                  SettingsProfilePreview(),
                  ActivitySharingSection(),
                ],
              ),
            ),
            SettingsPane(
              id: accountDevicesPane,
              label: 'Account & devices',
              icon: AppIcons.devices,
              builder: (context) => const Column(
                children: [
                  DevicesSection(),
                  ChangePasswordSection(),
                  TotpSection(),
                  AppLockSection(),
                  AccountSection(),
                ],
              ),
            ),
            SettingsPane(
              id: 'appearance',
              label: 'Appearance',
              icon: AppIcons.appearance,
              builder: (context) => const AppearanceSettingsSection(),
            ),
            SettingsPane(
              id: 'performance',
              label: ActionLabels.mediaAndCache,
              icon: AppIcons.performance,
              builder: (context) => const PerformanceSettingsSection(),
            ),
            SettingsPane(
              id: 'notifications',
              label: 'Notifications',
              icon: AppIcons.notificationsOn,
              builder: (context) => const NotificationsSection(),
            ),
            SettingsPane(
              id: 'voice',
              label: 'Voice & screen share',
              icon: AppIcons.voice,
              builder: (context) => const VoiceSettingsBody(),
            ),
          ],
        ),
        SettingsPaneGroup(
          label: 'Safety',
          panes: [
            SettingsPane(
              id: 'blocked',
              label: 'Blocked',
              icon: AppIcons.revoke,
              builder: (context) => const BlockedSection(),
            ),
            SettingsPane(
              id: 'report-status',
              label: 'Report status',
              icon: AppIcons.report,
              builder: (context) => const ReportStatusSection(),
            ),
          ],
        ),
        SettingsPaneGroup(
          label: 'App',
          panes: [
            SettingsPane(
              id: 'about',
              label: 'About slim-m',
              icon: AppIcons.info,
              builder: (context) => const AppInfoSection(),
            ),
          ],
        ),
      ],
    );
  }
}
