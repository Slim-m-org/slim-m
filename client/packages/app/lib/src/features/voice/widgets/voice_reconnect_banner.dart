// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bounded auto-rejoin's own feedback, laid over the call stage instead
/// of replacing it wholesale; see `voice_screen.dart`'s stage comment.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Shown only while [VoiceState.rejoining] is true, in the call stage's own
/// column under the header - the grid, filmstrip and dock stay put and
/// usable around it, unlike the full-screen spinner a first connection
/// still gets.
class VoiceReconnectBanner extends StatelessWidget {
  const VoiceReconnectBanner({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: AppSpacing.s12),
    child: AppCallout(
      tone: AppCalloutTone.warn,
      icon: AppIcons.retry,
      child: Text('Reconnecting to the call.'),
    ),
  );
}
