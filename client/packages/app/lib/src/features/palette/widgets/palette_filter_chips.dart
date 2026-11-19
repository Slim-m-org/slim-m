// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's committed filters, one chip each under the search field.
/// A chip is its own remove button; Backspace in an empty field removes the last.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/providers/message_search_query.dart';
import 'palette_filter_suggestions.dart';

class PaletteFilterChips extends StatelessWidget {
  const PaletteFilterChips({
    super.key,
    required this.filters,
    required this.onRemove,
    this.touch = false,
  });

  final List<SearchFilter> filters;
  final ValueChanged<SearchFilter> onRemove;
  final bool touch;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSpacing.s8,
    runSpacing: AppSpacing.s8,
    children: [
      for (final filter in filters)
        _FilterChip(
          filter: filter,
          touch: touch,
          onRemove: () => onRemove(filter),
        ),
    ],
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.touch,
    required this.onRemove,
  });

  final SearchFilter filter;
  final bool touch;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final shown = filter.label ?? filter.value;
    return AppTouchHitArea(
      touch: touch,
      child: FocusableTapTarget(
        key: ValueKey('palette-filter-${filter.typed}'),
        onTap: onRemove,
        semanticLabel: 'Remove filter ${filter.key.word}: $shown',
        ringRadius: AppRadii.full,
        builder: (context, focused, hovered) => Container(
          height: touch ? AppSizes.icon32 : AppSizes.icon24,
          padding: const EdgeInsets.only(
            left: AppSpacing.s8,
            right: AppSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: hovered ? tokens.surfaceSunken : tokens.surfaceBase,
            border: Border.all(color: tokens.borderStrong),
            borderRadius: BorderRadius.circular(AppRadii.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: AppSpacing.s4,
            children: [
              Icon(
                searchKeyIcon(filter.key),
                size: AppSizes.icon12,
                color: tokens.textSecondary,
              ),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${filter.key.word}:',
                        style: AppText.code.copyWith(
                          fontSize: AppText.caption.fontSize,
                          color: tokens.textSecondary,
                        ),
                      ),
                      TextSpan(
                        text: ' $shown',
                        style: AppText.caption.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                AppIcons.dismiss,
                size: AppSizes.icon12,
                color: hovered ? tokens.textPrimary : tokens.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
