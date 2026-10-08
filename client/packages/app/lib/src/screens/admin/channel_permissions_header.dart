// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid's header: one cell per principal column showing who
/// it is, what its overwrite currently does, and a control to drop it.
/// Split out of `channel_permissions_grid_rows.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../widgets/bot_avatar_placeholder.dart';
import '../../widgets/user_avatar.dart';
import 'channel_permissions_grid_rows.dart';

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
                        nameLines: metrics.compact ? 1 : 2,
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

/// One principal's header: avatar or role icon, its name, a one-glance count
/// of what it allows and denies, and the remove control.
class HeaderCell extends StatelessWidget {
  const HeaderCell({
    super.key,
    required this.column,
    required this.width,
    required this.onRemove,
    this.nameLines = 2,
  });

  final GridColumn column;
  final double width;
  final VoidCallback onRemove;
  final int nameLines;

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
                  Text(
                    column.label,
                    maxLines: nameLines,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(color: tokens.textPrimary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            ColumnSummary(
              key: ValueKey('summary:${column.key}'),
              allow: column.allowCount,
              deny: column.denyCount,
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

/// What a column's overwrite does, as words ("2 allow", "1 deny") so it never
/// rests on colour; reads "No overrides" when every cell inherits.
class ColumnSummary extends StatelessWidget {
  const ColumnSummary({super.key, required this.allow, required this.deny});

  final int allow;
  final int deny;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.micro.copyWith(color: tokens.textSecondary);
    final lines = [
      if (allow > 0) '$allow allow',
      if (deny > 0) '$deny deny',
      if (allow == 0 && deny == 0) 'No overrides',
    ];
    return Semantics(
      container: true,
      label: lines.join(', '),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Text(line, maxLines: 1, textAlign: TextAlign.center, style: style),
        ],
      ),
    );
  }
}
