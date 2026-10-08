// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid's presentational rows: the legend, the header row of
/// principal columns, a group header, one permission row, and one tri-state
/// cell. Split out of `channel_permissions_grid.dart`, which owns the state
/// and pending-changes logic these render.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'channel_permissions_cell.dart';

export 'channel_permissions_cell.dart';

/// One grid column: the role or member it targets, resolved for display.
class GridColumn {
  const GridColumn({
    required this.kind,
    required this.id,
    required this.label,
    required this.isBot,
    this.allowCount = 0,
    this.denyCount = 0,
  });

  final api.OverwriteTarget kind;
  final String id;
  final String label;
  final bool isBot;

  /// Permissions this column currently allows and denies, so its header says
  /// what the overwrite does without scanning every row.
  final int allowCount;
  final int denyCount;

  String get key => '${kind.wire}:$id';
}

/// Widths and heights every part of the grid aligns to, decided by the
/// space the grid actually has (`desktop-vs-mobile.md`: width, never
/// platform). Compact rows meet the 44dp touch minimum and, when the
/// principal columns fit, stretch to fill the width so none is ever cut.
class GridMetrics {
  const GridMetrics._({
    required this.labelWidth,
    required this.cellWidth,
    required this.rowHeight,
    required this.headerHeight,
    required this.contentWidth,
    required this.viewportWidth,
    required this.compact,
  });

  factory GridMetrics.forWidth(double width, {required int columnCount}) {
    final compact = width < kCompactWidth;
    final labelWidth = compact ? compactLabelWidth : wideLabelWidth;
    final viewport = (width - labelWidth).clamp(0.0, double.infinity);
    final slots = columnCount + 1;
    final double cellWidth;
    if (compact) {
      final fit = viewport / slots;
      cellWidth = fit >= minCellWidth
          ? fit.clamp(minCellWidth, maxCellWidth)
          : minCellWidth;
    } else {
      cellWidth = wideCellWidth;
    }
    return GridMetrics._(
      labelWidth: labelWidth,
      cellWidth: cellWidth,
      rowHeight: compact ? AppSizes.rowTouch : wideRowHeight,
      headerHeight: compact ? compactHeaderHeight : wideHeaderHeight,
      contentWidth: cellWidth * slots,
      viewportWidth: viewport,
      compact: compact,
    );
  }

  static const double compactLabelWidth = 132;
  static const double wideLabelWidth = 200;
  static const double minCellWidth = 60;
  static const double maxCellWidth = 96;
  static const double wideCellWidth = 88;
  static const double wideRowHeight = 40;
  static const double groupHeaderHeight = 40;
  static const double wideHeaderHeight = 124;

  /// Room for the remove button at its 44dp touch size.
  static const double compactHeaderHeight = 120;

  final double labelWidth;
  final double cellWidth;
  final double rowHeight;
  final double headerHeight;

  /// Width of every principal column plus the add column.
  final double contentWidth;

  /// Width left for those columns beside the pinned label column.
  final double viewportWidth;

  /// Phone-width layout: header names take one line, since a name wrapped in
  /// a narrow cell breaks mid-word.
  final bool compact;

  bool get scrolls => contentWidth > viewportWidth + 0.5;
}

class Legend extends StatelessWidget {
  const Legend({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    Widget item(CellState state, String label, {bool disabled = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CellChip(state: state, disabled: disabled, width: 24, height: 20),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
    return Wrap(
      spacing: AppSpacing.s16,
      runSpacing: AppSpacing.s8,
      children: [
        item(CellState.allow, 'Allow'),
        item(CellState.inherit, 'Inherit from role'),
        item(CellState.deny, 'Deny'),
        item(CellState.inherit, "you can't grant this", disabled: true),
        const _EditedKey(),
      ],
    );
  }
}

/// A group title in the pinned label column. Tapping it folds the group; the
/// chevron and the hidden-row count say so without relying on motion.
class GroupHeaderRow extends StatelessWidget {
  const GroupHeaderRow({
    super.key,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.count,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name = title.toUpperCase();
    return SizedBox(
      height: GridMetrics.groupHeaderHeight,
      child: FocusableTapTarget(
        semanticLabel:
            '$title, $count permissions, ${expanded ? 'expanded' : 'collapsed'}',
        onTap: onToggle,
        builder: (context, focused, hovered) => Padding(
          padding: const EdgeInsets.only(left: AppSpacing.s12),
          child: Row(
            children: [
              Icon(
                expanded ? AppIcons.chevronDown : AppIcons.chevronRight,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s4),
              Flexible(
                child: Text(
                  expanded ? name : '$name ($count)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.micro.copyWith(
                    color: hovered ? tokens.textPrimary : tokens.textSecondary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One permission's name in the pinned label column.
class GridLabelRow extends StatelessWidget {
  const GridLabelRow({super.key, required this.label, required this.height});

  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      height: height,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.s16, right: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// One permission's cells, one per principal column plus the add column's
/// empty slot, so it lines up under the header row.
class GridRow extends StatelessWidget {
  const GridRow({
    super.key,
    required this.columns,
    required this.metrics,
    required this.cellBuilder,
  });

  final List<GridColumn> columns;
  final GridMetrics metrics;
  final Widget Function(GridColumn column) cellBuilder;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: metrics.rowHeight,
    child: Row(
      children: [
        for (final column in columns)
          SizedBox(width: metrics.cellWidth, child: cellBuilder(column)),
        SizedBox(width: metrics.cellWidth),
      ],
    ),
  );
}

class AddColumnKindSheet extends StatelessWidget {
  const AddColumnKindSheet({super.key});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppListRow(
          leading: const Icon(AppIcons.shield),
          label: 'Add a role',
          onTap: () => Navigator.of(context).pop(api.OverwriteTarget.role),
        ),
        AppListRow(
          leading: const Icon(AppIcons.account),
          label: 'Add a member',
          onTap: () => Navigator.of(context).pop(api.OverwriteTarget.member),
        ),
      ],
    ),
  );
}

class _EditedKey extends StatelessWidget {
  const _EditedKey();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.textPrimary,
            shape: BoxShape.circle,
          ),
          child: const SizedBox(width: 9, height: 9),
        ),
        const SizedBox(width: 6),
        Text(
          'Edited, not saved',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }
}
