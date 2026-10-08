// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roles pane: a role list beside the selected role's detail, replacing
/// the old flat "Edit role" modal and separate "Assign" sheet with one
/// surface for "what may a role do, and who holds it" - see the 2026-09
/// design review's "06 Roles and permissions" section.
///
/// Two-pane on a wide enough embedding ([kRolesPaneTwoPaneWidth], checked
/// against this widget's own `LayoutBuilder` constraints rather than the
/// window - see that constant's doc), a role list that drills into the
/// detail on a narrower one. Desktop-vs-mobile rule 5 (a place with its own
/// nav you return to) and the translation table's "side pane -> drill-in
/// route with back".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../routing/breakpoints.dart';
import '../../routing/routes.dart';
import '../../widgets/role_color.dart';
import '../../widgets/run_guarded.dart';
import '../settings_screen_scaffold.dart';
import 'role_create_sheet.dart';
import 'role_detail.dart';
import '../../action_labels.dart';

class RolesScreen extends StatelessWidget {
  const RolesScreen({super.key});

  @override
  Widget build(BuildContext context) => SettingsScreenScaffold(
    title: 'Roles',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    scrollable: false,
    child: const RolesPane(),
  );
}

/// The role list and detail, embeddable as a Space settings pane as well as
/// routed. Owns which role is selected; wide layouts show both panes at
/// once, narrow ones show whichever is current.
class RolesPane extends ConsumerStatefulWidget {
  const RolesPane({super.key});

  @override
  ConsumerState<RolesPane> createState() => _RolesPaneState();
}

class _RolesPaneState extends ConsumerState<RolesPane> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    ref.watch(roleChangeWatcherProvider);
    final roles = ref.watch(rolesProvider);

    return AppAsyncView<List<api.Role>>(
      value: AppAsyncState(data: roles.valueOrNull, error: roles.error),
      center: false,
      errorMessage: 'Could not load roles.',
      onRetry: () => ref.invalidate(rolesProvider),
      data: (context, list) => LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= kRolesPaneTwoPaneWidth;

          // Narrow: the list only; a role's tabs are a real pushed route (Routes.adminRole), not a second app bar under this pane's own.
          if (!wide) {
            return _RoleNav(
              roles: list,
              selectedId: null,
              showSelection: false,
              onSelect: (id) => context.push(Routes.adminRole(id)),
            );
          }

          final selected = _select(list) ?? list.firstOrNull;
          final nav = _RoleNav(
            roles: list,
            selectedId: selected?.id,
            showSelection: true,
            onSelect: (id) => setState(() => _selectedId = id),
          );

          final tokens = Theme.of(context).extension<AppTokens>()!;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 240,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: tokens.borderSubtle),
                    ),
                  ),
                  child: nav,
                ),
              ),
              Expanded(
                child: selected == null
                    ? const SizedBox.shrink()
                    : RoleDetail(key: ValueKey(selected.id), role: selected),
              ),
            ],
          );
        },
      ),
    );
  }

  api.Role? _select(List<api.Role> roles) =>
      roles.where((r) => r.id == _selectedId).firstOrNull;
}

/// The role list: highest position first, a colour dot, member count, and a
/// drag handle once there are at least two non-`@everyone` roles to reorder.
class _RoleNav extends ConsumerStatefulWidget {
  const _RoleNav({
    required this.roles,
    required this.selectedId,
    required this.showSelection,
    required this.onSelect,
  });

  final List<api.Role> roles;
  final String? selectedId;
  final bool showSelection;
  final ValueChanged<String> onSelect;

  @override
  ConsumerState<_RoleNav> createState() => _RoleNavState();
}

class _RoleNavState extends ConsumerState<_RoleNav>
    with GuardedActionState<_RoleNav> {
  /// The arrangement a drag just produced, shown at once rather than waiting
  /// on the round trip - `category_reorder.dart`'s identical shape for the
  /// same reason: a drag that visibly snapped back while the request was
  /// still in flight would read as broken.
  List<String>? _pendingOrder;

  List<api.Role> get _ordered {
    final pending = _pendingOrder;
    if (pending == null) return widget.roles;
    final byId = {for (final r in widget.roles) r.id: r};
    final named = [
      for (final id in pending)
        if (byId[id] case final r?) r,
    ];
    final namedIds = named.map((r) => r.id).toSet();
    return [
      ...named,
      for (final r in widget.roles)
        if (!namedIds.contains(r.id)) r,
    ];
  }

  Future<void> _reorder(List<String> reorderableIds) async {
    setState(
      () => _pendingOrder = [
        ...reorderableIds,
        for (final r in widget.roles)
          if (r.isEveryone) r.id,
      ],
    );
    final ok = await guard(
      whatFailed: 'reorder roles',
      action: () => ref.read(apiProvider).reorderRoles(reorderableIds),
    );
    if (!mounted) return;
    setState(() => _pendingOrder = null);
    if (ok) ref.invalidate(rolesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ordered = _ordered;
    final reorderable = ordered.where((r) => !r.isEveryone).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s12,
            AppSpacing.s8,
            AppSpacing.s8,
            AppSpacing.s4,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'ROLES',
                  style: AppText.label.copyWith(color: tokens.textSecondary),
                ),
              ),
              AppIconButton(
                icon: AppIcons.add,
                semanticLabel: ActionLabels.createRole,
                tooltip: ActionLabels.createRole,
                onPressed: () => showCreateRoleSheet(context),
              ),
            ],
          ),
        ),
        if (actionError case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s8,
              vertical: AppSpacing.s4,
            ),
            child: AppErrorState(message: error, onDismiss: clearActionError),
          ),
        Expanded(
          child: reorderable.length < 2
              ? ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s8,
                  ),
                  children: [for (final role in ordered) _roleRow(role, null)],
                )
              : ReorderableListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s8,
                  ),
                  buildDefaultDragHandles: false,
                  onReorderItem: (oldIndex, newIndex) {
                    final ids = [for (final r in reorderable) r.id];
                    ids.insert(newIndex, ids.removeAt(oldIndex));
                    unawaited(_reorder(ids));
                  },
                  footer: Column(
                    children: [
                      for (final role in ordered)
                        if (role.isEveryone) _roleRow(role, null),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.s8,
                          AppSpacing.s8,
                          AppSpacing.s8,
                          0,
                        ),
                        child: Text(
                          'Drag to reorder.',
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  children: [
                    for (var i = 0; i < reorderable.length; i++)
                      KeyedSubtree(
                        key: ValueKey(reorderable[i].id),
                        child: _roleRow(reorderable[i], i),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _roleRow(api.Role role, int? dragIndex) => AppListRow(
    key: dragIndex == null ? ValueKey(role.id) : null,
    leading: DecoratedBox(
      decoration: BoxDecoration(
        color: roleColor(role.id),
        shape: BoxShape.circle,
      ),
      child: const SizedBox(width: 10, height: 10),
    ),
    label: role.name,
    meta: '${role.memberCount}',
    height: 34,
    selected: widget.showSelection && role.id == widget.selectedId,
    // Still fully editable and reorderable like any role; the tag only says who owns it (bots are full principals).
    trailing: role.isManagedByBot
        ? const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot')
        : null,
    trailingExtra: dragIndex == null
        ? null
        : ReorderableDragStartListener(
            index: dragIndex,
            child: Icon(
              AppIcons.dragHandle,
              size: AppSizes.icon16,
              color: Theme.of(context).extension<AppTokens>()!.textSecondary,
            ),
          ),
    onTap: () => widget.onSelect(role.id),
  );
}
