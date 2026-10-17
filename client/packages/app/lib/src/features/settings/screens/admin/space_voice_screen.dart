// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's call defaults: the screen-share ceiling and the default noise
/// suppression. Split out of "Retention and limits", which is about disk and
/// memory, where the owner found a voice setting out of place.
library;

import 'package:flutter/material.dart';

import '../../../../action_labels.dart';
import '../../../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import 'noise_suppression_default_section.dart';
import 'screen_share_cap_section.dart';

class SpaceVoiceScreen extends StatelessWidget {
  const SpaceVoiceScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: ActionLabels.spaceVoice,
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: SpaceVoicePane(),
  );
}

/// The call defaults, embeddable as a Space settings pane as well as routed.
class SpaceVoicePane extends StatelessWidget {
  const SpaceVoicePane({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [ScreenShareCapSection(), NoiseSuppressionDefaultSection()],
  );
}
