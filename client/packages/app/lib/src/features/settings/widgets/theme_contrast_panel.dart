// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The contrast floors of a theme file, shown while editing: every failing one
/// says what to change and offers the change.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_info_line.dart';
import 'settings_section_header.dart';

class ThemeContrastPanel extends StatelessWidget {
  const ThemeContrastPanel({
    super.key,
    required this.checks,
    required this.colours,
    required this.onFix,
    required this.onFixAll,
  });

  final List<ThemeContrastCheck> checks;
  final Map<String, Color> colours;
  final ValueChanged<ThemeContrastCheck> onFix;
  final VoidCallback onFixAll;

  @override
  Widget build(BuildContext context) {
    final failing = [
      for (final c in checks)
        if (!c.passes) c,
    ];
    return SettingsSectionCard(
      key: const Key('theme-contrast-panel'),
      title: 'Contrast',
      description: 'A theme must pass every check to be saved.',
      children: [
        if (failing.isEmpty)
          SettingsInfoLine(
            'All ${checks.length} checks pass.',
            key: const Key('theme-contrast-ok'),
          ),
        for (final check in failing)
          _FailingCheck(
            check: check,
            hint: check.hint(colours),
            onFix: () => onFix(check),
          ),
        if (failing.length > 1)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s12),
            child: Align(
              alignment: Alignment.centerRight,
              child: AppButton(
                key: const Key('theme-contrast-fix-all'),
                label: 'Fix all ${failing.length}',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.sm,
                onPressed: onFixAll,
              ),
            ),
          ),
      ],
    );
  }
}

class _FailingCheck extends StatelessWidget {
  const _FailingCheck({
    required this.check,
    required this.hint,
    required this.onFix,
  });

  final ThemeContrastCheck check;
  final String hint;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      key: Key('theme-check-${check.fg}-${check.bg}'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: AppSpacing.s8,
      ),
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          Icon(
            AppIcons.warning,
            size: AppSizes.icon16,
            color: tokens.dangerText,
          ),
          Expanded(
            child: Text(
              hint,
              style: AppText.ui.copyWith(color: tokens.textPrimary),
            ),
          ),
          AppButton(
            key: Key('theme-check-fix-${check.fg}-${check.bg}'),
            label: 'Fix',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            onPressed: onFix,
          ),
        ],
      ),
    );
  }
}
