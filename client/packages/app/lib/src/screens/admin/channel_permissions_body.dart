// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The permissions grid's scrolling frame: permission names pinned on the
/// left, principal columns scrolling sideways beside them, and an edge fade
/// with a chevron whenever more columns sit off to one side.
///
/// Compact width answers `desktop-vs-mobile.md`'s translation table for a
/// wide table: the same grid, but the label column stays put and the header
/// follows the body, rather than a table that scrolls its own labels away.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../permissions.dart';
import 'channel_permissions_grid_rows.dart';
import 'channel_permissions_header.dart';

class PermissionGridView extends StatefulWidget {
  const PermissionGridView({
    super.key,
    required this.columns,
    required this.filter,
    required this.cellBuilder,
    required this.onAdd,
    required this.onRemove,
  });

  final List<GridColumn> columns;

  /// Case-insensitive text a permission's name or description must contain;
  /// groups with no match drop out and a filter opens every group it hits.
  final String filter;
  final Widget Function(GridColumn column, PermSpec spec) cellBuilder;
  final VoidCallback onAdd;
  final ValueChanged<GridColumn> onRemove;

  @override
  State<PermissionGridView> createState() => _PermissionGridViewState();
}

class _PermissionGridViewState extends State<PermissionGridView> {
  final _body = ScrollController();
  final _header = ScrollController();
  final Set<String> _collapsed = {};

  /// Groups still worth showing for the current filter, each with the
  /// permissions that matched.
  List<PermGroup> _visibleGroups() {
    final needle = widget.filter.trim().toLowerCase();
    if (needle.isEmpty) return Perm.groups;
    return [
      for (final group in Perm.groups)
        if (group.permissions.where(
              (spec) =>
                  spec.label.toLowerCase().contains(needle) ||
                  spec.description.toLowerCase().contains(needle),
            )
            case final hits when hits.isNotEmpty)
          PermGroup(group.title, hits.toList()),
    ];
  }

  bool _isOpen(PermGroup group) =>
      widget.filter.trim().isNotEmpty || !_collapsed.contains(group.title);

  void _toggle(PermGroup group) => setState(() {
    if (!_collapsed.remove(group.title)) _collapsed.add(group.title);
  });

  @override
  void initState() {
    super.initState();
    _body.addListener(_followBody);
  }

  @override
  void dispose() {
    _body.removeListener(_followBody);
    _body.dispose();
    _header.dispose();
    super.dispose();
  }

  void _followBody() {
    if (!_header.hasClients || !_body.hasClients) return;
    final max = _header.position.maxScrollExtent;
    final target = _body.offset.clamp(0.0, max);
    if (_header.offset != target) _header.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final metrics = GridMetrics.forWidth(
        box.maxWidth,
        columnCount: widget.columns.length,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeaderRow(
            columns: widget.columns,
            metrics: metrics,
            controller: _header,
            onAdd: widget.onAdd,
            onRemove: widget.onRemove,
          ),
          Expanded(
            child: Stack(
              children: [
                _rows(metrics),
                if (metrics.scrolls)
                  Positioned(
                    left: metrics.labelWidth,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(child: _EdgeHints(controller: _body)),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _rows(GridMetrics metrics) {
    final groups = _visibleGroups();
    if (groups.isEmpty) return const _NoMatches();
    return _rowsFor(metrics, groups);
  }

  Widget _rowsFor(GridMetrics metrics, List<PermGroup> groups) =>
      SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: AppSpacing.s16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: metrics.labelWidth,
              child: Column(
                children: [
                  for (final group in groups) ...[
                    GroupHeaderRow(
                      title: group.title,
                      count: group.permissions.length,
                      expanded: _isOpen(group),
                      onToggle: () => _toggle(group),
                    ),
                    if (_isOpen(group))
                      for (final spec in group.permissions)
                        GridLabelRow(
                          label: spec.label,
                          height: metrics.rowHeight,
                        ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _body,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: metrics.contentWidth,
                  child: Column(
                    children: [
                      for (final group in groups) ...[
                        const SizedBox(height: GridMetrics.groupHeaderHeight),
                        if (_isOpen(group))
                          for (final spec in group.permissions)
                            GridRow(
                              columns: widget.columns,
                              metrics: metrics,
                              cellBuilder: (column) =>
                                  widget.cellBuilder(column, spec),
                            ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

/// Fades and a chevron on whichever side still has columns hidden.
class _EdgeHints extends StatelessWidget {
  const _EdgeHints({required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final ready =
          controller.hasClients && controller.position.hasContentDimensions;
      final offset = ready ? controller.offset : 0.0;
      final max = ready ? controller.position.maxScrollExtent : 1.0;
      return Stack(
        children: [
          if (offset > 0.5) const _Edge(atStart: true),
          if (offset < max - 0.5) const _Edge(atStart: false),
        ],
      );
    },
  );
}

class _Edge extends StatelessWidget {
  const _Edge({required this.atStart});

  final bool atStart;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final from = atStart ? Alignment.centerLeft : Alignment.centerRight;
    final to = atStart ? Alignment.centerRight : Alignment.centerLeft;
    return Positioned(
      left: atStart ? 0 : null,
      right: atStart ? null : 0,
      top: 0,
      bottom: 0,
      width: 36,
      child: DecoratedBox(
        key: ValueKey(atStart ? 'grid-scroll-back' : 'grid-scroll-more'),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: from,
            end: to,
            colors: [
              tokens.surfaceBase,
              tokens.surfaceBase.withValues(alpha: 0),
            ],
          ),
        ),
        child: Align(
          alignment: from,
          child: Transform.flip(
            flipX: atStart,
            child: Icon(
              AppIcons.chevronRight,
              size: AppSizes.icon16,
              color: tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s24),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          'No permissions match that filter.',
          style: AppText.ui.copyWith(color: tokens.textSecondary),
        ),
      ),
    );
  }
}
