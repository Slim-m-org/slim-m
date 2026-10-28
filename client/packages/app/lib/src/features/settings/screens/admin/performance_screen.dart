// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Space performance and capacity: message retention, the per-channel canvas
/// object cap, and the screen-share resolution ceiling.
///
/// Split out of `analytics_screen.dart`, which used to hold all three
/// alongside the usage-analytics toggle and charts even though none of the
/// three has anything to do with recording or reading usage: they are
/// capacity dials an admin reaches for regardless of whether analytics
/// recording is on, and analytics now holds only the toggle and the charts.
///
/// Requires MANAGE_SERVER, the same bit `/space/settings`, the Emoji screen,
/// and Analytics all require.
library;

import 'package:flutter/material.dart';

import '../../../../routing/routes.dart';
import '../settings_screen_scaffold.dart';
import 'attachment_limit_section.dart';
import 'canvas_cap_section.dart';
import 'link_previews_section.dart';
import 'media_compression_section.dart';
import 'retention_section.dart';
import '../../../../action_labels.dart';

export 'retention_section.dart'
    show
        retentionConfirmMessage,
        retentionConsequence,
        retentionCutoff,
        retentionDeletesHistory;

class PerformanceScreen extends StatelessWidget {
  const PerformanceScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: ActionLabels.retentionAndLimits,
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: PerformancePane(),
  );
}

/// The capacity controls, embeddable as a Space settings pane as well
/// as routed.
class PerformancePane extends StatelessWidget {
  const PerformancePane({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      RetentionSection(),
      CanvasCapSection(),
      AttachmentLimitSection(),
      MediaCompressionSection(),
      LinkPreviewsSection(),
    ],
  );
}
