// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A "choose one of these" sheet: a heading, an optional one-line caption,
/// then a row per item. `camera_source_sheet.dart` and
/// `screen_source_sheet.dart` were near-byte-identical copies of this shape,
/// differing only in heading text, icon and whether a caption was present;
/// this is the one implementation both now build on, the same collapsing
/// `member_roles_sheet.dart`'s own doc comment already flagged as owed
/// elsewhere in this codebase.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Renders [items] as a column of [AppListRow]s under [title], returning
/// whichever one the caller taps through [Navigator.pop]. [caption], when
/// given, sits between the title and the rows as a one-line explanation.
class DeviceChoiceSheet<T> extends StatelessWidget {
  const DeviceChoiceSheet({
    super.key,
    required this.title,
    this.caption,
    required this.icon,
    required this.items,
    required this.labelOf,
    this.isSelected,
  });

  final String title;
  final String? caption;
  final IconData icon;
  final List<T> items;
  final String Function(T item) labelOf;

  /// Marks one row as the one already in effect - a screen already being
  /// shared, reopened to switch to another. Null (every existing caller)
  /// marks nothing, the same shape [caption] already uses for "no opinion".
  final bool Function(T item)? isSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              caption == null ? AppSpacing.s12 : AppSpacing.s4,
            ),
            child: Text(title, style: AppText.heading),
          ),
          if (caption case final caption?)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s16,
                0,
                AppSpacing.s16,
                AppSpacing.s12,
              ),
              child: Text(
                caption,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          for (final item in items)
            AppListRow(
              label: labelOf(item),
              leading: Icon(
                icon,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              selected: isSelected?.call(item) ?? false,
              onTap: () => Navigator.of(context).pop(item),
            ),
          const SizedBox(height: AppSpacing.s8),
        ],
      ),
    );
  }
}
