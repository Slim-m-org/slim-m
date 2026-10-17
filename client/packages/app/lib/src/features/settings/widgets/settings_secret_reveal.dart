// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card that shows a secret exactly once (a bot token, a webhook URL).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';

/// [value] stays on screen until [onDismiss]; the server keeps only a hash.
class SettingsSecretReveal extends StatelessWidget {
  const SettingsSecretReveal({
    super.key,
    required this.warning,
    required this.value,
    required this.valueSemanticsLabel,
    required this.copyLabel,
    required this.onDismiss,
  });

  final String warning;
  final String value;
  final String valueSemanticsLabel;
  final String copyLabel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      children: [
        SettingsCardBlock(
          gap: AppSpacing.s12,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.s8,
              children: [
                Icon(AppIcons.warning, size: 18, color: tokens.warnText),
                Expanded(
                  child: Text(
                    warning,
                    style: AppText.caption.copyWith(color: tokens.textPrimary),
                  ),
                ),
              ],
            ),
            SelectableText(
              value,
              style: AppText.code,
              semanticsLabel: valueSemanticsLabel,
            ),
            Row(
              spacing: AppSpacing.s8,
              children: [
                AppButton(
                  label: copyLabel,
                  variant: AppButtonVariant.primary,
                  size: AppButtonSize.sm,
                  icon: AppIcons.copy,
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: value)),
                ),
                AppButton(
                  label: 'Done',
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.sm,
                  onPressed: onDismiss,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
