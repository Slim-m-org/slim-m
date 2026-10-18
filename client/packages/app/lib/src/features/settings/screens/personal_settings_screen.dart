// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Personal settings: what the account holder controls about themselves, open
/// to every signed-in caller. The nav groups panes by what each follows (You,
/// App, Safety, Help), per the addendum in
/// docs/decisions/0013-settings-container-system.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../widgets/settings_section_header.dart';
import '../../members/widgets/activity_sharing_section.dart';
import '../../../widgets/app_info_section.dart';
import '../../../widgets/app_lock_section.dart';
import '../widgets/appearance_settings_section.dart';
import '../widgets/connections_section.dart';
import '../widgets/general_settings_section.dart';
import '../widgets/performance_settings_section.dart';
import '../../members/widgets/avatar_settings_section.dart';
import '../widgets/personal_account_sections.dart';
import '../widgets/personal_status_sections.dart';
import '../../members/widgets/profile_fields_section.dart';
import '../../members/widgets/report_status_section.dart';
import '../widgets/settings_panes.dart';
import '../widgets/settings_profile_preview.dart';
import '../widgets/totp_section.dart';
import '../widgets/troubleshooting_pane.dart';
import '../../auth/widgets/change_password_section.dart';
import '../../voice/screens/voice_settings_screen.dart';
import '../../../action_labels.dart';
import '../providers/settings_index.dart';

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
      searchEntries: personalSettingsIndex,
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
                  SettingsProfilePreview(),
                  AvatarSettingsSection(),
                  ProfileFieldsSection(),
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
                  ConnectionsSection(),
                  _SignInSection(),
                  AppLockSection(),
                  AccountSection(),
                ],
              ),
            ),
          ],
        ),
        SettingsPaneGroup(
          label: 'App',
          panes: [
            SettingsPane(
              id: 'appearance',
              label: 'Appearance',
              icon: AppIcons.appearance,
              builder: (context) => const AppearanceSettingsSection(),
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
            SettingsPane(
              id: 'performance',
              label: ActionLabels.mediaAndCache,
              icon: AppIcons.performance,
              builder: (context) => const PerformanceSettingsSection(),
            ),
            SettingsPane(
              id: 'general',
              label: ActionLabels.general,
              icon: AppIcons.settings,
              builder: (context) => const GeneralSettingsSection(),
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
          label: 'Help',
          panes: [
            SettingsPane(
              id: 'troubleshooting',
              label: 'Troubleshooting',
              icon: AppIcons.troubleshooting,
              builder: (context) => const TroubleshootingPane(),
              headingBuilder: (context, onClose) =>
                  TroubleshootingHeading(onClose: onClose),
            ),
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

/// Password and two-factor together: both are how you prove it is you, and
/// one card of rows reads lighter than a card per single button.
class _SignInSection extends ConsumerWidget {
  const _SignInSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(totpStatusProvider).valueOrNull;
    final hideTotp = status != null && totpSectionHidden(status);
    return SettingsSectionCard(
      title: 'Sign-in',
      description: "How you prove it's you on a new device.",
      children: [
        const ChangePasswordSection(embedded: true),
        if (!hideTotp) const TotpSection(),
      ],
    );
  }
}
