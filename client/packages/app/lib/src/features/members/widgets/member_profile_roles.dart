// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card's Roles section, the way Discord shows one: a small heading, then
/// a pill per role (its colour as a dot, its name in its own case), highest
/// position first. A member with no roles has no section, unless the viewer
/// can grant one: they get the heading and a "+" pill.
///
/// The "+" opens the same toggles the Moderate view shows, in place
/// (`docs/design/desktop-vs-mobile.md`, rule 3: an inline expander, never a
/// second popover); on touch the whole heading line is that control. On a
/// pointer a pill the viewer may take away shows a cross on hover or focus;
/// on touch that is done through the toggles. Both follow [RoleLadder], your
/// own card included, so neither offers what the server would refuse.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/admin_providers.dart';
import '../../../role_ladder.dart';
import '../../../widgets/run_guarded.dart';
import 'member_moderate_roles.dart';
import 'role_color.dart';

/// Dot, cross and "+" glyph share one box, so a hover swap never moves text.
const double _markSize = AppSizes.icon12;

/// The card's menu rows sit this far in from its edge; see `_Section`.
const double _rowInset = 6;

/// One held role as the card draws it.
typedef _HeldRole = ({String? id, String name, int? color});

class MemberProfileRoles extends ConsumerStatefulWidget {
  const MemberProfileRoles({
    super.key,
    required this.profile,
    this.canManageRoles = false,
  });

  final api.UserProfile profile;

  /// The viewer holds MANAGE_ROLES; [RoleLadder] says which roles that reaches.
  final bool canManageRoles;

  @override
  ConsumerState<MemberProfileRoles> createState() => _MemberProfileRolesState();
}

class _MemberProfileRolesState extends ConsumerState<MemberProfileRoles>
    with GuardedActionState<MemberProfileRoles> {
  bool _editing = false;

  List<_HeldRole> get _held {
    final p = widget.profile;
    return [
      for (var i = 0; i < p.roles.length; i++)
        (
          id: i < p.roleIds.length ? p.roleIds[i] : null,
          name: p.roles[i],
          color: i < p.roleColors.length ? p.roleColors[i] : null,
        ),
    ];
  }

  Future<void> _set(api.Role role, bool grant) => setMemberRole(
    ref,
    guard,
    memberId: widget.profile.id,
    role: role,
    grant: grant,
  );

  RoleLock? _lock(RoleLadder ladder, api.Role role) => ladder.lockOf(
    role,
    member: widget.profile,
    held: widget.profile.roleIds.contains(role.id),
  );

  @override
  Widget build(BuildContext context) {
    final held = _held;
    final rolesAsync = widget.canManageRoles ? ref.watch(rolesProvider) : null;
    final roles = rolesAsync?.valueOrNull;
    final ladder = ref.watch(roleLadderProvider);
    // Until the roles load, the + stays: opening it is where loading or a failure shows.
    final manage =
        rolesAsync != null &&
        (roles?.any((r) => _lock(ladder, r) == null) ?? true);
    if (held.isEmpty && !manage) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    api.Role? removable(String? id) {
      if (touch || id == null) return null;
      final role = roles?.where((r) => r.id == id).firstOrNull;
      return role != null && _lock(ladder, role) == null ? role : null;
    }

    final name = widget.profile.displayName;
    final heading = Semantics(
      header: true,
      child: Text(
        'ROLES',
        style: AppText.label.copyWith(color: tokens.textSecondary),
      ),
    );
    Widget toggle({Widget? heading}) => _RolesToggle(
      open: _editing,
      semanticLabel: 'Roles for $name',
      onTap: () => setState(() => _editing = !_editing),
      heading: heading,
    );
    final section = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s4,
      children: [
        if (!(manage && touch)) heading,
        Wrap(
          spacing: AppSpacing.s4,
          runSpacing: AppSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final role in held)
              _RolePill(
                name: role.name,
                color: role.color,
                onRemove: switch (removable(role.id)) {
                  final r? => () => _set(r, false),
                  null => null,
                },
                removeLabel: 'Remove ${role.name} from $name',
              ),
            if (manage && !touch) toggle(),
          ],
        ),
        if (actionError case final error?)
          AppErrorState(message: error, onDismiss: clearActionError),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Out at the menu-row inset, so its press tint lines up with the rows below.
        if (manage && touch)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _rowInset),
            child: toggle(heading: heading),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            manage && _editing ? AppSpacing.s4 : AppSpacing.s12,
          ),
          child: section,
        ),
        if (rolesAsync != null && manage && _editing)
          _toggles(rolesAsync, ladder),
      ],
    );
  }

  Widget _toggles(AsyncValue<List<api.Role>> rolesAsync, RoleLadder ladder) {
    final roles = rolesAsync.valueOrNull;
    if (roles == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          0,
          AppSpacing.s16,
          AppSpacing.s12,
        ),
        child: rolesAsync.hasError
            ? AppErrorState(
                message: 'Could not load the roles.',
                onRetry: () => ref.invalidate(rolesProvider),
              )
            : const Center(child: AppSpinner()),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _rowInset,
        0,
        _rowInset,
        AppSpacing.s8,
      ),
      child: MemberRoleToggles(
        roles: [
          for (final role in roles)
            if (!role.isEveryone) role,
        ],
        member: widget.profile,
        ladder: ladder,
        onChanged: _set,
      ),
    );
  }
}

/// A role's pill. With [onRemove] its dot turns into a cross while the pill
/// is hovered or the cross holds focus.
class _RolePill extends StatefulWidget {
  const _RolePill({
    required this.name,
    required this.color,
    required this.onRemove,
    required this.removeLabel,
  });

  final String name;

  /// The role's palette index, or null for the neutral dot.
  final int? color;
  final VoidCallback? onRemove;
  final String removeLabel;

  @override
  State<_RolePill> createState() => _RolePillState();
}

class _RolePillState extends State<_RolePill> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final dot = roleDotColor(widget.color, tokens);
    final onRemove = widget.onRemove;
    final crossShown = onRemove != null && (_hovered || _focused);
    Widget mark = AnimatedSwitcher(
      duration: AppMotion.reduced(context, AppMotion.fast),
      child: crossShown
          ? Icon(
              AppIcons.dismiss,
              key: const ValueKey('cross'),
              size: _markSize,
              color: tokens.textPrimary,
            )
          : _Dot(key: const ValueKey('dot'), color: dot),
    );
    if (onRemove != null) {
      mark = FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (on) => setState(() => _focused = on),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => onRemove(),
          ),
        },
        child: Semantics(
          button: true,
          label: widget.removeLabel,
          onTap: onRemove,
          child: GestureDetector(onTap: onRemove, child: mark),
        ),
      );
    }
    final pill = _PillFrame(
      children: [
        mark,
        const SizedBox(width: AppSpacing.s4),
        Flexible(
          child: Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.medium,
            ),
          ),
        ),
      ],
    );
    if (onRemove == null) return pill;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: pill,
    );
  }
}

/// Opens and closes the role toggles: a "+" pill after the role pills on a
/// pointer, and on touch the whole heading line, so the target is a full
/// touch row without stretching one line of pills taller than the others.
class _RolesToggle extends StatelessWidget {
  const _RolesToggle({
    required this.open,
    required this.semanticLabel,
    required this.onTap,
    this.heading,
  });

  final bool open;
  final String semanticLabel;
  final VoidCallback onTap;

  /// The section heading, given only on touch, where this is the heading line.
  final Widget? heading;

  @override
  Widget build(BuildContext context) {
    final heading = this.heading;
    final mark = _AddMark(open: open);
    final button = Semantics(
      button: true,
      expanded: open,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: heading == null
            ? mark
            : ConstrainedBox(
                constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s16 - _rowInset,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: heading),
                      mark,
                    ],
                  ),
                ),
              ),
      ),
    );
    if (heading != null) return button;
    return Tooltip(
      message: open ? 'Done' : 'Add role',
      excludeFromSemantics: true,
      child: button,
    );
  }
}

/// The drawn "+" pill, a chevron while the toggles are open.
class _AddMark extends StatelessWidget {
  const _AddMark({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _PillFrame(
      selected: open,
      children: [
        // As tall as a role pill's name line, so a line of pills keeps one height.
        SizedBox(
          height: MediaQuery.textScalerOf(
            context,
          ).scale(AppText.caption.fontSize! * AppText.caption.height!),
          child: Icon(
            open ? AppIcons.chevronUp : AppIcons.add,
            size: _markSize,
            color: open ? tokens.textPrimary : tokens.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The shape every pill in the section shares.
class _PillFrame extends StatelessWidget {
  const _PillFrame({required this.children, this.selected = false});

  final List<Widget> children;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: selected ? tokens.accentSoft : tokens.surfaceBase,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: _markSize,
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}
