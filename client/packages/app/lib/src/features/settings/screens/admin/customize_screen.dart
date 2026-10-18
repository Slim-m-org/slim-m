// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the Space presents itself to someone new: its profile and invite
/// landing page, the welcome message, and the join gate they agree to. Moved
/// out of Invites, which now only issues and lists invite codes.
library;

import 'package:flutter/material.dart';

import '../../../../routing/routes.dart';
import '../../../members/widgets/invite_landing_section.dart';
import '../../widgets/join_gate_section.dart';
import '../../widgets/welcome_section.dart';
import '../settings_screen_scaffold.dart';

class CustomizeScreen extends StatelessWidget {
  const CustomizeScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Customize',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: CustomizePane(),
  );
}

/// The customisation sections, embeddable as a Space settings pane as well as routed.
class CustomizePane extends StatelessWidget {
  const CustomizePane({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [InviteLandingSection(), WelcomeSection(), JoinGateSection()],
  );
}
