// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A read-only row inside a flush settings card: a label and its value.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

class SettingsValueRow extends StatelessWidget {
  const SettingsValueRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;

  /// Machine-ish values (ids, codes) read in the mono face.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical,
        ),
        child: Row(
          spacing: AppSpacing.s16,
          children: [
            Text(label, style: AppText.ui.copyWith(color: tokens.textPrimary)),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: tokens.textSecondary,
                  fontFamily: mono ? AppFonts.mono : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
