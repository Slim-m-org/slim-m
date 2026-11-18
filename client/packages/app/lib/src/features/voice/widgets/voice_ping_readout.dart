// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's audio round trip as a number in the header, which opens the connection details.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../connection/widgets/connection_details.dart';
import '../providers/voice_ping.dart';

/// Tints [style] by [voicePingTier], or amber when [routeConcern] says the route is far
/// or slow; empty until the first sample lands.
class VoicePingReadout extends ConsumerStatefulWidget {
  const VoicePingReadout({
    super.key,
    required this.style,
    this.routeConcern = false,
  });

  final TextStyle style;
  final bool routeConcern;

  @override
  ConsumerState<VoicePingReadout> createState() => _VoicePingReadoutState();
}

class _VoicePingReadoutState extends ConsumerState<VoicePingReadout> {
  bool _highlighted = false;

  @override
  Widget build(BuildContext context) {
    final ms = ref.watch(voicePingProvider);
    if (ms == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final tier = voicePingTier(ms);
    final color = switch (tier) {
      VoicePingTier.poor => tokens.dangerText,
      VoicePingTier.fair => tokens.warnText,
      VoicePingTier.good when widget.routeConcern => tokens.warnText,
      VoicePingTier.good => tokens.textSecondary,
    };
    void open() => showConnectionDetails(context);
    // The highlight is an underline, not a ring: a ring's room would push the header's line apart.
    return Semantics(
      // The tier, not the number: a figure that moves every sample would churn what a screen reader hears.
      label: 'Connection details, voice ping ${tier.name}',
      button: true,
      excludeSemantics: true,
      onTap: open,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (on) => setState(() => _highlighted = on),
        onShowFocusHighlight: (on) => setState(() => _highlighted = on),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => open(),
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: open,
          child: Text(
            voicePingLabel(ms),
            style: widget.style.copyWith(
              color: color,
              decoration: _highlighted ? TextDecoration.underline : null,
              decorationColor: color,
            ),
          ),
        ),
      ),
    );
  }
}
