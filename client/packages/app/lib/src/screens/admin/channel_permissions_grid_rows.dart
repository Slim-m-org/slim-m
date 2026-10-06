// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid's presentational rows: the legend, the header row of
/// principal columns, a group header, one permission row, and one tri-state
/// cell. Split out of `channel_permissions_grid.dart`, which owns the state
/// and pending-changes logic these render.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/bot_avatar_placeholder.dart';
import '../../widgets/user_avatar.dart';
import 'channel_permissions_cell.dart';

export 'channel_permissions_cell.dart';

/// One grid column: the role or member it targets, resolved for display.
class GridColumn {
  const GridColumn({
    required this.kind,
    required this.id,
    required this.label,
    required this.isBot,
  });

  final api.OverwriteTarget kind;
  final String id;
  final String label;
  final bool isBot;

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
    );
  }

  static const double compactLabelWidth = 132;
  static const double wideLabelWidth = 220;
  static const double minCellWidth = 60;
  static const double maxCellWidth = 96;
  static const double wideCellWidth = 72;
  static const double wideRowHeight = 40;
  static const double groupHeaderHeight = 32;
  static const double wideHeaderHeight = 72;

  /// Room for the remove button at its 44dp touch size.
  static const double compactHeaderHeight = 88;

  final double labelWidth;
  final double cellWidth;
  final double rowHeight;
  final double headerHeight;

  /// Width of every principal column plus the add column.
  final double contentWidth;

  /// Width left for those columns beside the pinned label column.
  final double viewportWidth;

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
      ],
    );
  }
}

/// The principal columns' headers, kept in step with the body by
/// [controller]; the body is what the user drags.
class HeaderRow extends StatelessWidget {
  const HeaderRow({
    super.key,
    required this.columns,
    required this.metrics,
    required this.controller,
    required this.onAdd,
    required this.onRemove,
  });

  final List<GridColumn> columns;
  final GridMetrics metrics;
  final ScrollController controller;
  final VoidCallback onAdd;

  /// Removing a column clears its pending state - a full inherit, applied on
  /// save the same way any other pending edit is.
  final ValueChanged<GridColumn> onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: SizedBox(
        height: metrics.headerHeight,
        child: Row(
          children: [
            SizedBox(width: metrics.labelWidth),
            Expanded(
              child: SingleChildScrollView(
                controller: controller,
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final column in columns)
                      HeaderCell(
                        column: column,
                        width: metrics.cellWidth,
                        onRemove: () => onRemove(column),
                      ),
                    SizedBox(
                      width: metrics.cellWidth,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.s8),
                        child: Center(
                          child: AppIconButton(
                            icon: AppIcons.add,
                            semanticLabel: 'Add a role or member to this grid',
                            onPressed: onAdd,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One principal's header: avatar or role icon, its name when it fits, and
/// the remove control.
class HeaderCell extends StatelessWidget {
  const HeaderCell({
    super.key,
    required this.column,
    required this.width,
    required this.onRemove,
  });

  final GridColumn column;
  final double width;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: column.label,
              triggerMode: TooltipTriggerMode.tap,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  column.kind == api.OverwriteTarget.role
                      ? Icon(
                          AppIcons.shield,
                          size: AppSizes.icon16,
                          color: tokens.textSecondary,
                        )
                      : UserAvatar(
                          name: column.label,
                          userId: column.id,
                          size: AppAvatarSize.s20,
                          shape: column.isBot
                              ? AppAvatarShape.square
                              : AppAvatarShape.circle,
                          placeholder: column.isBot
                              ? botAvatarPlaceholder(context, column.label)
                              : null,
                        ),
                  const SizedBox(height: AppSpacing.s4),
                  _HeaderName(label: column.label),
                ],
              ),
            ),
            AppIconButton(
              icon: AppIcons.dismiss,
              iconSize: AppSizes.icon16,
              size: AppIconButtonSize.sm,
              semanticLabel: 'Remove ${column.label} from this grid',
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// The column's name, shown only when the whole of it fits the cell. A name
/// that does not fit collapses to its avatar (the tooltip carries it) rather
/// than painting a mid-word ellipsis, and keeps its line height so avatars
/// across headers stay level.
class _HeaderName extends StatelessWidget {
  const _HeaderName({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.caption.copyWith(color: tokens.textPrimary);
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    return LayoutBuilder(
      builder: (context, box) => SizedBox(
        height: size.height,
        child: size.width <= box.maxWidth
            ? Text(label, maxLines: 1, softWrap: false, style: style)
            : null,
      ),
    );
  }
}

/// A group title in the pinned label column.
class GroupHeaderRow extends StatelessWidget {
  const GroupHeaderRow({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SizedBox(
      height: GridMetrics.groupHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.only(
          left: AppSpacing.s16,
          bottom: AppSpacing.s4,
        ),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Text(
            title.toUpperCase(),
            style: AppText.micro.copyWith(
              color: tokens.textSecondary,
              fontWeight: AppWeights.medium,
            ),
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
/// empty slot, so it lines up under [HeaderRow].
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
