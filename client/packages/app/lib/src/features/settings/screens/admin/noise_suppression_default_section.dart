// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's default noise suppression, next to the screen-share ceiling
/// since both shape what a call costs and sounds like.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart';

import '../../widgets/space_setting_switch_section.dart';

class NoiseSuppressionDefaultSection extends StatelessWidget {
  const NoiseSuppressionDefaultSection({super.key});

  @override
  Widget build(BuildContext context) => SpaceSettingSwitchSection(
    title: 'Noise suppression',
    cardDescription: 'For members who leave it on Space default.',
    label: 'Strong by default',
    description: 'Also removes keyboards, fans and room noise.',
    semanticLabel: 'Strong noise suppression by default',
    whatFailed: 'change the default noise suppression',
    read: (settings) => settings.strongNoiseSuppression,
    update: (enabled) => SpaceSettingsUpdate(strongNoiseSuppression: enabled),
  );
}
