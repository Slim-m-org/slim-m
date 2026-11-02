// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Says in the call stage's own flow that our connection is breaking up.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_health.dart';
import 'call_tile_badges.dart';

/// The banner's callout, for tests to find.
const poorConnectionBannerKey = ValueKey('poor-connection-banner');

/// Shown while the health model flags our own audio, so a person whose
/// connection is the problem is told in text rather than by a corner glyph
/// (desktop-vs-mobile rule 6: a degraded call is a banner). Nothing shows
/// while all is well, and the 5 s and 10 s hysteresis is the model's own.
class PoorConnectionBanner extends ConsumerWidget {
  const PoorConnectionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final poor = ref.watch(poorConnectionsProvider);
    final me = ref
        .watch(voiceParticipantsProvider)
        .where((p) => p.isLocal && poor.contains(p.identity))
        .firstOrNull;
    if (me == null) return const SizedBox.shrink();
    return StatusBanner(
      key: poorConnectionBannerKey,
      severity: BannerSeverity.warning,
      sticky: true,
      icon: AppIcons.connectionPoor,
      message: poorConnectionMessage(me),
      margin: const EdgeInsets.only(top: AppSpacing.s12),
    );
  }
}
