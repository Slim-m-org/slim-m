// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's round trip to the voice server as a number in the header.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_ping.dart';

/// Tints [style] by [voicePingTier]; empty until the first sample lands.
class VoicePingReadout extends ConsumerWidget {
  const VoicePingReadout({super.key, required this.style});

  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = ref.watch(voicePingProvider);
    if (ms == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final color = switch (voicePingTier(ms)) {
      VoicePingTier.good => tokens.textSecondary,
      VoicePingTier.fair => tokens.warnText,
      VoicePingTier.poor => tokens.dangerText,
    };
    return Semantics(
      label: 'Voice ping ${voicePingLabel(ms)}',
      excludeSemantics: true,
      child: Text(voicePingLabel(ms), style: style.copyWith(color: color)),
    );
  }
}
