// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's connection state beside its name: a dot and the word for it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../members/widgets/presence_indicator.dart';

/// Shape and word carry the state too, so colour is never the only cue.
class BotStatusBadge extends StatelessWidget {
  const BotStatusBadge({super.key, required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final word = online ? 'Online' : 'Offline';
    return Semantics(
      label: 'Bot $word',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s4,
        children: [
          PresenceIndicator(
            presence: online ? AppPresence.online : AppPresence.offline,
            size: 8,
            backgroundColor: tokens.surfaceRaised,
          ),
          Text(
            word,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
