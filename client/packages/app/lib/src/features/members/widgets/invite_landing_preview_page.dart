// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin's "preview as a visitor": the real join view on its own page, so it is not a card stacked into the settings pane.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'invite_landing_card.dart';
import 'invite_landing_view.dart';

class InviteLandingPreviewPage extends StatelessWidget {
  const InviteLandingPreviewPage({super.key, required this.card});

  final InviteLandingCard card;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Preview as a visitor'),
      leading: IconButton(
        icon: const Icon(AppIcons.back),
        tooltip: 'Back to Customize',
        onPressed: () => Navigator.of(context).pop(),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: InviteLandingView(
            card: card,
            onBack: () => Navigator.of(context).pop(),
            note: 'This is what someone opening one of your invites sees.',
          ),
        ),
      ),
    ),
  );
}
