// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's Display tab: name, its colour (a palette entry or
/// none - see `widgets/role_color.dart`), and the mentionable flag. `@everyone` cannot be renamed, mentioned as `@[Role Name]` (it wakes
/// through the reserved `@everyone`/`@here` words instead) or deleted, so
/// those controls are simply absent for it rather than disabled and unclear
/// why. A role out of the viewer's reach shows its settings without letting them change.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../members/providers/member_presence.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/color_swatch_row.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../members/widgets/role_color.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

class RoleDisplayTab extends ConsumerStatefulWidget {
  const RoleDisplayTab({super.key, required this.role, this.locked = false});

  final api.Role role;

  /// The role is not below the viewer's highest; see `role_detail.dart`.
  final bool locked;

  @override
  ConsumerState<RoleDisplayTab> createState() => _RoleDisplayTabState();
}

class _RoleDisplayTabState extends ConsumerState<RoleDisplayTab>
    with GuardedActionState<RoleDisplayTab> {
  late final TextEditingController _name = TextEditingController(
    text: widget.role.name,
  );
  bool _busy = false;

  @override
  void didUpdateWidget(RoleDisplayTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role.id != widget.role.id) _name.text = widget.role.name;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _renameIfChanged() async {
    final name = _name.text.trim();
    if (name.isEmpty || name == widget.role.name) return;
    final ok = await guard(
      whatFailed: 'rename the role',
      action: () =>
          ref.read(apiProvider).updateRole(roleId: widget.role.id, name: name),
    );
    if (ok && mounted) ref.invalidate(rolesProvider);
  }

  Future<void> _setMentionable(bool value) async {
    final ok = await guard(
      whatFailed: 'update mentions',
      action: () => ref
          .read(apiProvider)
          .updateRole(roleId: widget.role.id, mentionable: value),
    );
    if (ok && mounted) ref.invalidate(rolesProvider);
  }

  /// A null [index] takes the colour away.
  Future<void> _setColor(int? index) async {
    final ok = await guard(
      whatFailed: 'change the colour',
      action: () => ref
          .read(apiProvider)
          .updateRole(
            roleId: widget.role.id,
            color: index,
            clearColor: index == null,
          ),
    );
    if (!ok || !mounted) return;
    ref.invalidate(rolesProvider);
    ref.invalidate(membersProvider);
  }

  Future<void> _setHoist(bool value) async {
    final ok = await guard(
      whatFailed: 'update the member list',
      action: () => ref
          .read(apiProvider)
          .updateRole(roleId: widget.role.id, hoist: value),
    );
    if (!ok || !mounted) return;
    ref.invalidate(rolesProvider);
    ref.invalidate(membersProvider);
    ref.invalidate(channelMembersProvider);
  }

  Future<void> _delete() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete "${widget.role.name}"?',
      message:
          'Members holding this role lose whatever it grants immediately. '
          'This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'delete the role',
      action: () => ref.read(apiProvider).deleteRole(widget.role.id),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(rolesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    final locked = widget.locked;
    final unchanged =
        _name.text.trim().isEmpty || _name.text.trim() == role.name;

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.s24, 0, AppSpacing.s24, 40),
      children: [
        SettingsSectionCard(
          title: 'Name',
          children: [
            if (role.isEveryone || locked)
              SettingsDetailRow(title: role.name)
            else
              SettingsCardBlock(
                gap: AppSpacing.s12,
                children: [
                  AppInput(
                    maxLength: api.InputLimits.name,
                    controller: _name,
                    placeholder: 'Role name',
                    semanticLabel: 'Role name',
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _renameIfChanged(),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppButton(
                      label: 'Save name',
                      variant: AppButtonVariant.secondary,
                      size: AppButtonSize.sm,
                      disabled: unchanged,
                      onPressed: _renameIfChanged,
                    ),
                  ),
                ],
              ),
          ],
        ),
        SettingsSectionCard(
          title: 'Colour',
          description: 'Colours member names and the role dot.',
          children: [
            SettingsCardBlock(
              children: [
                Opacity(
                  // Dimmed like the locked toggles below it.
                  opacity: locked ? 0.6 : 1,
                  child: ColorSwatchRow(
                    label: 'Role colour',
                    colors: [for (final entry in rolePalette) entry.color],
                    names: [for (final entry in rolePalette) entry.name],
                    selected: chosenRoleIndex(role.color),
                    onSelect: locked ? null : _setColor,
                    leading: SwatchTile(
                      icon: AppIcons.revoke,
                      label: 'Role colour: No colour',
                      selected: chosenRoleIndex(role.color) == null,
                      onTap: locked ? null : () => _setColor(null),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (!role.isEveryone)
          SettingsSectionCard(
            title: 'Display',
            children: [
              SettingsToggleRow(
                label: 'Anyone can @mention this role',
                description: 'Whatever their permissions.',
                semanticLabel: 'Anyone can @mention this role',
                value: role.mentionable,
                onChanged: locked ? null : _setMentionable,
              ),
              SettingsToggleRow(
                label: 'Display role members separately',
                description: 'Gives this role its own heading above Online.',
                semanticLabel: 'Display role members separately',
                value: role.hoist,
                onChanged: locked ? null : _setHoist,
              ),
            ],
          ),
        if (actionError case final error?) ...[
          const SizedBox(height: AppSpacing.s12),
          AppErrorState(message: error, onDismiss: clearActionError),
        ],
        if (!role.isEveryone && !role.isBotsRole && !locked)
          SettingsSectionCard(
            title: 'Danger zone',
            children: [
              SettingsActionRow(
                message:
                    'Members holding this role lose what it grants immediately.',
                action: AppButton(
                  label: 'Delete role',
                  variant: AppButtonVariant.danger,
                  size: AppButtonSize.sm,
                  disabled: _busy,
                  onPressed: _delete,
                ),
              ),
            ],
          ),
      ],
    );
  }
}
