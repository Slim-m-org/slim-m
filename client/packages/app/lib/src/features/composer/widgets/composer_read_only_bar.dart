// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What stands in the composer's place where you cannot send messages.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';

class ComposerReadOnlyBar extends StatelessWidget {
  const ComposerReadOnlyBar({super.key});

  static const String message = 'You cannot send messages here.';

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      // The composer's own gutter, so the slot does not jump sideways when Send is revoked.
      padding: EdgeInsets.fromLTRB(
        paneGutterOf(context),
        0,
        paneGutterOf(context),
        AppSpacing.s8,
      ),
      child: const AppCallout(
        tone: AppCalloutTone.info,
        icon: AppIcons.restrictedChannel,
        child: Text(message),
      ),
    ),
  );
}
