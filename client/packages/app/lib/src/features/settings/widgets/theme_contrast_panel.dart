// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The contrast floors of a theme file, shown while editing and grouped by the
/// colour to change: one row per failing colour, with its worst check and a
/// Fix that clears all of that colour's checks.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';
import 'theme_colour_chip.dart';

class ThemeContrastPanel extends StatelessWidget {
  const ThemeContrastPanel({
    super.key,
    required this.checks,
    required this.colours,
    required this.onFixColour,
    required this.onFixAll,
  });

  final List<ThemeContrastCheck> checks;
  final Map<String, Color> colours;
  final ValueChanged<String> onFixColour;
  final VoidCallback onFixAll;

  @override
  Widget build(BuildContext context) {
    final failing = [
      for (final c in checks)
        if (!c.passes) c,
    ];
    final byColour = <String, List<ThemeContrastCheck>>{
      for (final token in themeTokenGroups.expand((g) => g.tokens))
        if (failing.any((c) => c.fg == token))
          token: [
            for (final c in failing)
              if (c.fg == token) c,
          ],
    };
    return SettingsSectionCard(
      key: const Key('theme-contrast-panel'),
      title: 'Contrast',
      description: 'A theme must pass every check to be saved.',
      children: [
        if (failing.isEmpty)
          _Summary(
            key: const Key('theme-contrast-ok'),
            icon: AppIcons.allPassed,
            text: 'All ${checks.length} checks pass.',
          )
        else
          _Summary(
            icon: AppIcons.warning,
            warn: true,
            text: _failSentence(byColour.length, failing.length),
            action: AppButton(
              key: const Key('theme-contrast-fix-all'),
              label: 'Fix all',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.sm,
              onPressed: onFixAll,
            ),
          ),
        for (final MapEntry(key: token, value: list) in byColour.entries)
          _FailingColour(
            token: token,
            colour: colours[token]!,
            hint: themeContrastHint(list, colours),
            onFix: () => onFixColour(token),
          ),
      ],
    );
  }
}

String _failSentence(int colours, int checks) {
  final who = colours == 1 ? '1 colour fails' : '$colours colours fail';
  return '$who $checks ${checks == 1 ? 'check' : 'checks'}.';
}

/// What to do about one colour's failing [checks], judged by the worst of them.
String themeContrastHint(
  List<ThemeContrastCheck> checks,
  Map<String, Color> colours,
) {
  final worst = checks.reduce(
    (a, b) => b.ratio / b.min < a.ratio / a.min ? b : a,
  );
  if (worst.quieter) return 'Make it quieter than Secondary text.';
  final fixed = worst.fix(colours);
  final lighter =
      fixed != null &&
      fixed.computeLuminance() > colours[worst.fg]!.computeLuminance();
  return 'Make it ${lighter ? 'lighter' : 'darker'}: '
      '${worst.ratio.toStringAsFixed(1)}:1 at worst, '
      'needs ${worst.min.toStringAsFixed(1)}:1.';
}

class _Summary extends StatelessWidget {
  const _Summary({
    super.key,
    required this.icon,
    required this.text,
    this.warn = false,
    this.action,
  });

  final IconData icon;
  final String text;
  final bool warn;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _CardRow(
      children: [
        Icon(
          icon,
          size: AppSizes.icon20,
          color: warn ? tokens.warnText : tokens.textPrimary,
        ),
        Expanded(
          child: Text(
            text,
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
        ),
        ?action,
      ],
    );
  }
}

class _FailingColour extends StatelessWidget {
  const _FailingColour({
    required this.token,
    required this.colour,
    required this.hint,
    required this.onFix,
  });

  final String token;
  final Color colour;
  final String hint;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _CardRow(
      key: Key('theme-check-$token'),
      children: [
        ThemeColourChip(colour: colour),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              Text(
                themeTokenLabels[token]!,
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
              Text(
                hint,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
        AppButton(
          key: Key('theme-check-fix-$token'),
          label: 'Fix',
          semanticLabel: 'Fix ${themeTokenLabels[token]}',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: onFix,
        ),
      ],
    );
  }
}

/// A card row at the card's own metrics, its children spaced like a list row's.
class _CardRow extends StatelessWidget {
  const _CardRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final metrics = SettingsRowMetrics.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical,
        ),
        child: Row(spacing: AppSpacing.s12, children: children),
      ),
    );
  }
}
