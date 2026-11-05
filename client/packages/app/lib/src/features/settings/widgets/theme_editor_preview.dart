// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small chat window painted with the theme being edited, so every token
/// shows up somewhere before the theme is saved.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeEditorPreview extends StatelessWidget {
  const ThemeEditorPreview({
    super.key,
    required this.document,
    this.compact = false,
  });

  final ThemeDocument document;

  /// Drops the sidebar and the second message for a phone's short strip.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = document.tokens;
    return Theme(
      data: buildTheme(document.brightness, tokens),
      child: Builder(
        builder: (context) => DecoratedBox(
          key: const Key('theme-editor-preview'),
          decoration: BoxDecoration(
            color: tokens.surfaceBase,
            borderRadius: BorderRadius.circular(AppRadii.card),
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.card),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!compact) _Rail(tokens: tokens),
                  Expanded(
                    child: _Chat(tokens: tokens, compact: compact),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: tokens.surfaceSunken,
    child: SizedBox(
      width: 104,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _channel(tokens, 'general', selected: true),
            _channel(tokens, 'music'),
            _channel(tokens, 'builds', muted: true),
          ],
        ),
      ),
    ),
  );

  Widget _channel(
    AppTokens tokens,
    String name, {
    bool selected = false,
    bool muted = false,
  }) => DecoratedBox(
    decoration: BoxDecoration(
      color: selected ? tokens.accentSoft : null,
      borderRadius: BorderRadius.circular(AppRadii.control),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: Row(
        spacing: AppSpacing.s4,
        children: [
          Icon(
            AppIcons.hash,
            size: AppSizes.icon16,
            color: selected ? tokens.accent : tokens.textSecondary,
          ),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(
                color: selected
                    ? tokens.accent
                    : muted
                    ? tokens.textDisabled
                    : tokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Chat extends StatelessWidget {
  const _Chat({required this.tokens, required this.compact});

  final AppTokens tokens;
  final bool compact;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        _message(
          'Ren',
          'Pine at dusk is up. Have a look at the new theme.',
          '9:41',
          tokens.textPrimary,
        ),
        if (!compact)
          DecoratedBox(
            decoration: BoxDecoration(color: tokens.stripe),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
              child: _message(
                'Kai',
                'Reads well. The links are a bit dim.',
                null,
                tokens.textSecondary,
              ),
            ),
          ),
        Wrap(
          spacing: AppSpacing.s8,
          runSpacing: AppSpacing.s4,
          children: [
            Text(
              'Link to the build',
              style: AppText.ui.copyWith(color: tokens.accent),
            ),
            Text(
              'Delete failed',
              style: AppText.ui.copyWith(color: tokens.dangerText),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.warnSoft,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
                child: Text(
                  'Low battery',
                  style: AppText.ui.copyWith(color: tokens.warnText),
                ),
              ),
            ),
          ],
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadii.card),
            border: Border.all(color: tokens.borderStrong),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: Row(
              spacing: AppSpacing.s8,
              children: [
                Expanded(
                  child: Text(
                    'Message #general',
                    style: AppText.ui.copyWith(color: tokens.textDisabled),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.accentFill,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    border: Border.all(color: tokens.accentRing, width: 2),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s12,
                      vertical: AppSpacing.s4,
                    ),
                    child: Text(
                      'Send',
                      style: AppText.ui.copyWith(color: tokens.accentOn),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!compact)
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: tokens.dangerBorder),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s8,
                vertical: AppSpacing.s4,
              ),
              child: Text(
                'Could not send. Try again.',
                style: AppText.caption.copyWith(color: tokens.dangerText),
              ),
            ),
          ),
        if (!compact)
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: tokens.focusRing, width: 2),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s4),
              child: Text(
                'Focused control',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _message(String who, String text, String? time, Color body) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        spacing: AppSpacing.s8,
        children: [
          Text(
            who,
            maxLines: 1,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          if (time != null)
            Text(
              time,
              style: AppText.micro.copyWith(color: tokens.textDisabled),
            ),
        ],
      ),
      Text(text, style: AppText.ui.copyWith(color: body)),
    ],
  );
}
