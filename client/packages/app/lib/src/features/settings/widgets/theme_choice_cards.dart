// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme picker: one small window per choice, drawn in that theme's own
/// colours, ringed in the accent when chosen.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;

class ThemeChoiceCards extends StatelessWidget {
  const ThemeChoiceCards({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final AppThemeChoice selected;
  final ValueChanged<AppThemeChoice> onChanged;

  static Key cardKey(AppThemeChoice choice) => Key('theme_card_${choice.name}');

  static const _order = [
    AppThemeChoice.dark,
    AppThemeChoice.softDark,
    AppThemeChoice.light,
    AppThemeChoice.trueBlack,
    AppThemeChoice.catppuccin,
    AppThemeChoice.forest,
    AppThemeChoice.system,
  ];

  @override
  Widget build(BuildContext context) {
    // Width decides (desktop-vs-mobile.md, the one rule): seven across crowd any pane.
    final columns = MediaQuery.sizeOf(context).width < kCompactWidth ? 2 : 4;
    final cards = [
      for (final choice in _order)
        _ThemeCard(
          choice: choice,
          selected: choice == selected,
          onTap: () => onChanged(choice),
        ),
    ];
    return Column(
      spacing: AppSpacing.s16,
      children: [
        for (var i = 0; i < cards.length; i += columns)
          Row(
            spacing: 10,
            children: [
              for (var j = i; j < i + columns; j++)
                // A short last row keeps every card a column's width.
                Expanded(
                  child: j < cards.length ? cards[j] : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );
  }
}

class _ThemeCard extends StatelessWidget {
  _ThemeCard({
    required this.choice,
    required this.selected,
    required this.onTap,
  }) : super(key: ThemeChoiceCards.cardKey(choice));

  final AppThemeChoice choice;
  final bool selected;
  final VoidCallback onTap;

  String get _label => switch (choice) {
    AppThemeChoice.system => 'System',
    AppThemeChoice.light => 'Light',
    AppThemeChoice.dark => 'Dark',
    AppThemeChoice.trueBlack => 'True black',
    AppThemeChoice.catppuccin => 'Catppuccin',
    AppThemeChoice.softDark => 'Soft dark',
    AppThemeChoice.forest => 'Forest',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // The ring is always drawn so selecting a card never shifts its neighbours.
    final ring = selected ? tokens.accent : Colors.transparent;
    final labelColor = selected ? tokens.accent : tokens.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: _label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control + 3),
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 6,
            children: [
              AnimatedContainer(
                duration: AppMotion.reduced(context, AppMotion.fast),
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.control + 3),
                  border: Border.all(color: ring, width: 2),
                ),
                child: _Thumbnail(choice: choice),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  spacing: 4,
                  children: [
                    Flexible(
                      child: Text(
                        _label,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: labelColor,
                          fontWeight: selected ? AppWeights.semi : null,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(AppIcons.check, size: 14, color: tokens.accent),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.choice});

  final AppThemeChoice choice;

  @override
  Widget build(BuildContext context) {
    final current = Theme.of(context).extension<AppTokens>()!;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: current.borderSubtle),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control - 1),
        child: choice == AppThemeChoice.system
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ColoredBox(color: AppTokens.light.surfaceBase),
                  ),
                  Expanded(
                    child: ColoredBox(color: AppTokens.dark.surfaceBase),
                  ),
                ],
              )
            : _Window(
                tokens: switch (choice) {
                  AppThemeChoice.light => AppTokens.light,
                  AppThemeChoice.dark => AppTokens.dark,
                  AppThemeChoice.trueBlack => AppTokens.trueBlack,
                  AppThemeChoice.catppuccin => AppTokens.mocha,
                  AppThemeChoice.softDark => AppTokens.soft,
                  AppThemeChoice.forest => AppTokens.forest,
                  AppThemeChoice.system => throw StateError(
                    'system is drawn as a split, not a window',
                  ),
                },
              ),
      ),
    );
  }
}

class _Window extends StatelessWidget {
  const _Window({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceSunken,
              border: Border(right: BorderSide(color: tokens.borderSubtle)),
            ),
            child: const SizedBox.expand(),
          ),
        ),
        Expanded(
          flex: 7,
          child: ColoredBox(
            color: tokens.surfaceBase,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 5,
                children: [
                  _Bar(color: tokens.textPrimary, fraction: 0.6),
                  _Bar(color: tokens.textSecondary, fraction: 0.8),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.fraction});

  final Color color;
  final double fraction;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: fraction,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
      child: const SizedBox(height: 5),
    ),
  );
}
