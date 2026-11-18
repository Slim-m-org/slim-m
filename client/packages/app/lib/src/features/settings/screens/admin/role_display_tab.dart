// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's Display tab: name, its colour (a palette entry or
/// none - see `widgets/role_color.dart`), and the mentionable and hoist flags,
/// held as one draft behind the same Save bar the Permissions tab uses. `@everyone` cannot be renamed, mentioned as `@[Role Name]` (it wakes
/// through the reserved `@everyone`/`@here` words instead) or deleted, so
/// those controls are simply absent for it rather than disabled and unclear
/// why. A role out of the viewer's reach shows its settings without letting them change.
library;

import 'dart:async';

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
import '../../widgets/settings_save_bar.dart';
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

  /// The edits the Save bar holds; null is "as the role is now".
  ({int? index})? _color;
  bool? _mentionable;
  bool? _hoist;
  bool _busy = false;
  bool _saving = false;

  @override
  void didUpdateWidget(RoleDisplayTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.role.id != widget.role.id) {
      _name.text = widget.role.name;
      _color = _mentionable = _hoist = null;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmedName => _name.text.trim();

  bool get _nameChanged =>
      _trimmedName.isNotEmpty && _trimmedName != widget.role.name;

  bool get _colorChanged =>
      _color != null && _color!.index != chosenRoleIndex(widget.role.color);

  bool get _mentionableChanged =>
      _mentionable != null && _mentionable != widget.role.mentionable;

  bool get _hoistChanged => _hoist != null && _hoist != widget.role.hoist;

  int get _pendingCount => [
    _nameChanged,
    _colorChanged,
    _mentionableChanged,
    _hoistChanged,
  ].where((changed) => changed).length;

  void _discard() => setState(() {
    _name.text = widget.role.name;
    _color = _mentionable = _hoist = null;
  });

  Future<void> _save() async {
    if (_pendingCount == 0 || _saving) return;
    final index = _color?.index;
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'save the role',
      action: () => ref
          .read(apiProvider)
          .updateRole(
            roleId: widget.role.id,
            name: _nameChanged ? _trimmedName : null,
            mentionable: _mentionableChanged ? _mentionable : null,
            hoist: _hoistChanged ? _hoist : null,
            color: _colorChanged ? index : null,
            clearColor: _colorChanged && index == null,
          ),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    ref.invalidate(rolesProvider);
    if (_colorChanged || _hoistChanged) ref.invalidate(membersProvider);
    if (_hoistChanged) ref.invalidate(channelMembersProvider);
    setState(() => _color = _mentionable = _hoist = null);
  }

  static String _deleteMessage(int holders) {
    final who = switch (holders) {
      0 => 'No one holds this role.',
      1 => 'The 1 member holding it loses whatever it grants immediately.',
      _ =>
        'The $holders members holding it lose whatever it grants immediately.',
    };
    return '$who Invites that grant it will grant no role. '
        'This cannot be undone.';
  }

  Future<void> _delete() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete "${widget.role.name}"?',
      message: _deleteMessage(widget.role.memberCount),
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
    final color = _color == null ? chosenRoleIndex(role.color) : _color!.index;

    final list = ListView(
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
                    onSubmitted: (_) => unawaited(_save()),
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
                    selected: color,
                    onSelect: locked
                        ? null
                        : (index) => setState(() => _color = (index: index)),
                    leading: SwatchTile(
                      icon: AppIcons.revoke,
                      label: 'Role colour: No colour',
                      selected: color == null,
                      onTap: locked
                          ? null
                          : () => setState(() => _color = (index: null)),
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
                value: _mentionable ?? role.mentionable,
                onChanged: locked
                    ? null
                    : (value) => setState(() => _mentionable = value),
              ),
              SettingsToggleRow(
                label: 'Display role members separately',
                description: 'Gives this role its own heading above Online.',
                semanticLabel: 'Display role members separately',
                value: _hoist ?? role.hoist,
                onChanged: locked
                    ? null
                    : (value) => setState(() => _hoist = value),
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
    // One tree shape either way, so the save bar appearing never remounts the list and its focus.
    return Column(
      children: [
        Expanded(child: list),
        if (_pendingCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s24,
              0,
              AppSpacing.s24,
              AppSpacing.s16,
            ),
            child: SettingsSaveBar(
              changeCount: _pendingCount,
              saving: _saving,
              onDiscard: _discard,
              onSave: () => unawaited(_save()),
            ),
          ),
      ],
    );
  }
}
