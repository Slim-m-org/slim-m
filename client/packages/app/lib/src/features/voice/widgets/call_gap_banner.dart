// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Says when the server's list of who is in the call disagrees with what this device's call delivered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';
import '../providers/call_roster_gap.dart';

/// What the banner says about [pending]; null when nobody is pending.
String? pendingPeersLine(List<PendingPeer> pending) => switch (pending) {
  [] => null,
  [final one] => '${one.name} is in the call but not connected to you yet.',
  [final a, final b] =>
    '${a.name} and ${b.name} are in the call but not connected to you yet.',
  _ => '${pending.length} people are in the call but not connected to you yet.',
};

/// The gap as a banner, or [child] while there is none; one banner at a time (rule 6).
class CallGapBanner extends ConsumerWidget {
  const CallGapBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gap = ref.watch(callRosterGapProvider);
    final message = gap.selfMissing
        ? "The call server lost you. Others may not hear you right now."
        : pendingPeersLine(gap.connecting);
    if (message == null) return child;
    return StatusBanner(
      severity: BannerSeverity.warning,
      sticky: true,
      icon: AppIcons.connectionPoor,
      message: message,
      margin: const EdgeInsets.only(top: AppSpacing.s12),
    );
  }
}
