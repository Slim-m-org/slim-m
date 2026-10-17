// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one empty state for a settings or admin list: a sentence in a card.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The sentence alone, for a card that already exists around it.
class SettingsEmptyLine extends StatelessWidget {
  const SettingsEmptyLine(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s8),
      child: Text(
        message,
        style: AppText.body.copyWith(color: tokens.textSecondary),
      ),
    );
  }
}

/// The design's centred empty card body: a round glyph, a title, one detail line.
class SettingsEmptyState extends StatelessWidget {
  const SettingsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [
          ExcludeSemantics(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tokens.surfaceBase,
                shape: BoxShape.circle,
                border: Border.all(color: tokens.borderSubtle),
              ),
              child: Icon(icon, size: 20, color: tokens.textSecondary),
            ),
          ),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.medium,
            ),
          ),
          if (detail != null)
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
        ],
      ),
    );
  }
}
