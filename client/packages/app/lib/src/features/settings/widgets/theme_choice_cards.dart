// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme picker: one card per choice, each with a small window drawn in
/// that theme's own colours.
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
    AppThemeChoice.light,
    AppThemeChoice.trueBlack,
    AppThemeChoice.system,
  ];

  @override
  Widget build(BuildContext context) {
    // Four across wrap "True black" mid-word on a phone, so it goes two by two.
    final narrow = MediaQuery.sizeOf(context).width < kCompactWidth;
    final cards = [
      for (final choice in _order)
        _ThemeCard(
          choice: choice,
          selected: choice == selected,
          onTap: () => onChanged(choice),
        ),
    ];
    if (narrow) {
      return Column(
        spacing: 10,
        children: [
          for (var i = 0; i < cards.length; i += 2)
            Row(
              spacing: 10,
              children: [
                Expanded(child: cards[i]),
                Expanded(child: cards[i + 1]),
              ],
            ),
        ],
      );
    }
    return Row(
      spacing: 10,
      children: [for (final card in cards) Expanded(child: card)],
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
  };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final outline = selected ? tokens.textPrimary : tokens.borderSubtle;
    return Semantics(
      button: true,
      selected: selected,
      label: _label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.s8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: outline, width: selected ? 2 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: AppSpacing.s8,
              children: [
                _Thumbnail(choice: choice),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _label,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                    ),
                    if (selected)
                      Icon(AppIcons.check, size: 14, color: tokens.textPrimary),
                  ],
                ),
              ],
            ),
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
                  AppThemeChoice.trueBlack => AppTokens.trueBlack,
                  _ => AppTokens.dark,
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
