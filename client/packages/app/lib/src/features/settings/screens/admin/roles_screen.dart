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
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../routing/breakpoints.dart';
import '../../../../routing/routes.dart';
import '../../../../widgets/hover_reveal.dart';
import '../../../members/providers/member_presence.dart' show membersProvider;
import '../../../members/widgets/role_color.dart';
import '../../../../permissions.dart' show joinLabels;
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_sub_pages.dart';
import '../settings_screen_scaffold.dart';
import 'role_create_sheet.dart';
import 'role_detail.dart';
import 'role_holder_avatar.dart';
import '../../../../action_labels.dart';

class RolesScreen extends StatelessWidget {
  const RolesScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Roles',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    scrollable: false,
    child: RolesPane(),
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

  /// Opens another role once the open one's unsaved edits are saved or let go.
  Future<void> _selectRole(BuildContext context, String id) async {
    final pane = SettingsSubPages.maybeOf(context);
    if (pane != null && !await pane.canLeave()) return;
    if (mounted) setState(() => _selectedId = id);
  }

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
            onSelect: (id) => unawaited(_selectRole(context, id)),
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
/// drag handle on each role below the viewer's highest once there are at
/// least two non-`@everyone` roles to reorder.
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
    final startedFrom = [
      for (final r in widget.roles)
        if (!r.isEveryone) r.id,
    ];
    setState(
      () => _pendingOrder = [
        ...reorderableIds,
        for (final r in widget.roles)
          if (r.isEveryone) r.id,
      ],
    );
    await guard(
      whatFailed: 'reorder roles',
      action: () => ref
          .read(apiProvider)
          .reorderRoles(reorderableIds, expectedRoleIds: startedFrom),
    );
    if (!mounted) return;
    await _refetchRoles();
    if (mounted) setState(() => _pendingOrder = null);
  }

  /// Reorders after a drop; one that puts a bot's role above another role asks first, since the bot then manages it.
  Future<void> _drop(List<api.Role> roles, int oldIndex, int newIndex) async {
    final ids = [for (final r in roles) r.id];
    ids.insert(newIndex, ids.removeAt(oldIndex));
    final gaining = _botRolesGainingReach(roles, ids);
    if (gaining.isNotEmpty &&
        !await _confirmBotReach(roles[oldIndex], gaining)) {
      return;
    }
    await _reorder(ids);
  }

  Future<bool> _confirmBotReach(api.Role moved, List<api.Role> bots) {
    if (bots.contains(moved)) {
      return confirmChoice(
        context,
        title: 'Move ${moved.name} up?',
        message:
            'Bots with this role can then manage roles and members below its new place.',
        confirmLabel: 'Move up',
      );
    }
    final names = joinLabels([for (final r in bots) r.name]);
    return confirmChoice(
      context,
      title: 'Move ${moved.name} below $names?',
      message: 'Bots with $names can then manage this role and its members.',
      confirmLabel: 'Move down',
    );
  }

  /// The dropped order stays on screen until the roles it describes arrive.
  Future<void> _refetchRoles() async {
    try {
      ref.invalidate(rolesProvider);
      await ref.read(rolesProvider.future);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'The roles refetch after a reorder failed; the pane shows it',
        error,
        stack,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ladder = ref.watch(roleLadderProvider);
    final ordered = _ordered;
    final reorderable = ordered.where((r) => !r.isEveryone).toList();
    final canReorder =
        reorderable.length >= 2 && reorderable.any(ladder.reachesRole);

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
              // A new role starts at the bottom, which only someone above it may then manage.
              if (ladder.reachesPosition(0))
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
          child: !canReorder
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
                  onReorderItem: (oldIndex, newIndex) =>
                      unawaited(_drop(reorderable, oldIndex, newIndex)),
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
                        child: _MoveByKeyboard(
                          enabled: ladder.reachesRole(reorderable[i]),
                          onMove: (step) {
                            final to = i + step;
                            if (to < 0 || to >= reorderable.length) return;
                            unawaited(_drop(reorderable, i, to));
                          },
                          child: HoverReveal(
                            builder: (context, hovered, _, focused) => _roleRow(
                              reorderable[i],
                              ladder.reachesRole(reorderable[i]) ? i : null,
                              showHandle: hovered || focused,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// A null [dragIndex] draws the row without a handle, keeping its width.
  Widget _roleRow(api.Role role, int? dragIndex, {bool showHandle = false}) {
    final bot = _botOf(role);
    return AppListRow(
      key: dragIndex == null ? ValueKey(role.id) : null,
      leading: bot != null
          ? roleHolderAvatar(context, bot, size: AppAvatarSize.s20)
          : DecoratedBox(
              decoration: BoxDecoration(
                color: roleDotColor(
                  role.color,
                  Theme.of(context).extension<AppTokens>()!,
                ),
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 10, height: 10),
            ),
      label: role.name,
      subtitle: bot?.displayName,
      meta: '${role.memberCount}',
      height: bot == null ? 34 : null,
      selected: widget.showSelection && role.id == widget.selectedId,
      // Rows stay at their real rank (decision 0092); the bot's name under the role's says whose it is.
      trailing: role.isManagedByBot || role.isBotsRole
          ? const AppBadge(variant: AppBadgeVariant.tag, label: 'Bot')
          : null,
      trailingExtra: _dragHandle(dragIndex, showHandle: showHandle),
      onTap: () => widget.onSelect(role.id),
    );
  }

  api.UserProfile? _botOf(api.Role role) {
    final botId = role.managedBotId;
    if (botId == null) return null;
    final members = ref.watch(membersProvider).valueOrNull;
    return members?.where((m) => m.id == botId).firstOrNull;
  }

  Widget _dragHandle(int? dragIndex, {required bool showHandle}) {
    // A row that cannot be dragged keeps the handle's width so the member counts line up.
    if (dragIndex == null) return const SizedBox(width: AppSizes.icon16);
    final visible = showHandle || AppTouchTargets.of(context);
    return ReorderableDragStartListener(
      index: dragIndex,
      // Faded in place rather than swapped in, so hovering never changes the row's shape.
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.reduced(context, AppMotion.fast),
        child: Icon(
          AppIcons.dragHandle,
          size: AppSizes.icon16,
          color: Theme.of(context).extension<AppTokens>()!.textSecondary,
        ),
      ),
    );
  }
}

/// Alt+Up and Alt+Down, and the screen reader's Move up and Move down, move the focused role one place.
class _MoveByKeyboard extends StatelessWidget {
  const _MoveByKeyboard({
    required this.enabled,
    required this.onMove,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<int> onMove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
            onMove(-1),
        const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): () =>
            onMove(1),
      },
      child: Semantics(
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Move up'): () => onMove(-1),
          const CustomSemanticsAction(label: 'Move down'): () => onMove(1),
        },
        child: child,
      ),
    );
  }
}

/// The bot roles [after] (ids, top first) puts above a role they sat below in [before].
List<api.Role> _botRolesGainingReach(
  List<api.Role> before,
  List<String> after,
) {
  final was = {for (final (i, r) in before.indexed) r.id: i};
  final now = {for (final (i, id) in after.indexed) id: i};
  return [
    for (final bot in before)
      if ((bot.isBotsRole || bot.isManagedByBot) &&
          before.any(
            (r) => was[bot.id]! > was[r.id]! && now[bot.id]! < now[r.id]!,
          ))
        bot,
  ];
}
