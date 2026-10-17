// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected role's Permissions tab: Administrator, then every grantable
/// permission grouped and described, module permissions folded into the
/// same list rather than a separate section below the fold. Edits batch
/// until Save; a permission the caller does not themselves hold is shown
/// disabled rather than silently refused later.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../permissions.dart';
import '../../../../providers/admin_providers.dart';
import '../../../modules/providers/app_launch.dart';
import '../../../modules/providers/code_block_runner.dart';
import '../../../../providers/providers.dart';
import '../../../composer/providers/slash_command.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_save_bar.dart';
import '../../widgets/settings_section_header.dart';
import 'role_permissions_rows.dart';

const _administratorDescription =
    'Every permission below, in every channel, ignoring overrides.';

/// The pane's horizontal inset, so cards line up with the role header above.
const _inset = AppSpacing.s24;

class RolePermissionsTab extends ConsumerStatefulWidget {
  const RolePermissionsTab({super.key, required this.role});

  final api.Role role;

  @override
  ConsumerState<RolePermissionsTab> createState() => _RolePermissionsTabState();
}

class _RolePermissionsTabState extends ConsumerState<RolePermissionsTab>
    with GuardedActionState<RolePermissionsTab> {
  final TextEditingController _filter = TextEditingController();
  final Map<int, bool> _bitOverrides = {};
  final Map<String, bool> _moduleOverrides = {};
  bool _saving = false;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  int get _pendingCount => _bitOverrides.length + _moduleOverrides.length;

  void _setBit(int bit, bool value, bool original) {
    setState(() {
      if (value == original) {
        _bitOverrides.remove(bit);
      } else {
        _bitOverrides[bit] = value;
      }
    });
  }

  void _setModule(String key, bool value, bool original) {
    setState(() {
      if (value == original) {
        _moduleOverrides.remove(key);
      } else {
        _moduleOverrides[key] = value;
      }
    });
  }

  void _discard() => setState(() {
    _bitOverrides.clear();
    _moduleOverrides.clear();
  });

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await guard(whatFailed: 'save permissions', action: _applyAll);
    if (!mounted) return;
    setState(() => _saving = false);
    ref.invalidate(rolesProvider);
    ref.invalidate(roleModulePermissionsProvider(widget.role.id));
    ref.invalidate(codeBlockRunnerProvider);
    ref.invalidate(slashCommandProvider);
    ref.invalidate(appLaunchProvider);
    if (ok) _discard();
  }

  Future<void> _applyAll() async {
    await _applyBits();
    for (final entry in _moduleOverrides.entries.toList()) {
      await _applyModule(entry.key, entry.value);
      if (mounted) setState(() => _moduleOverrides.remove(entry.key));
    }
  }

  Future<void> _applyBits() async {
    var permissions = widget.role.permissions;
    for (final entry in _bitOverrides.entries) {
      permissions = entry.value
          ? (permissions | entry.key)
          : (permissions & ~entry.key);
    }
    if (permissions == widget.role.permissions) return;
    await ref
        .read(apiProvider)
        .updateRole(roleId: widget.role.id, permissions: permissions);
    if (mounted) setState(_bitOverrides.clear);
  }

  Future<void> _applyModule(String key, bool granted) {
    final parts = key.split(':');
    final moduleId = parts[0];
    final permKey = parts.sublist(1).join(':');
    final client = ref.read(apiProvider);
    return granted
        ? client.grantModulePermission(
            roleId: widget.role.id,
            moduleId: moduleId,
            permKey: permKey,
          )
        : client.revokeModulePermission(
            roleId: widget.role.id,
            moduleId: moduleId,
            permKey: permKey,
          );
  }

  bool _matchesFilter(String label, String description) {
    final needle = _filter.text.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return label.toLowerCase().contains(needle) ||
        description.toLowerCase().contains(needle);
  }

  @override
  Widget build(BuildContext context) {
    final myPermissions = ref.watch(myPermissionsProvider);
    final catalog =
        ref.watch(modulePermissionsProvider).valueOrNull ?? const [];
    final granted = ref
        .watch(roleModulePermissionsProvider(widget.role.id))
        .valueOrNull;
    final grantedKeys = {
      for (final g in granted ?? const <api.GrantedModulePermission>[])
        '${g.moduleId}:${g.permKey}',
    };
    final held = widget.role.permissions;

    final showAdministrator = _matchesFilter(
      'Administrator',
      _administratorDescription,
    );
    final groups = [
      for (final group in Perm.groups)
        (
          group,
          [
            for (final spec in group.permissions)
              if (_matchesFilter(spec.label, spec.description)) spec,
          ],
        ),
    ].where((g) => g.$2.isNotEmpty).toList();
    final modules = granted == null
        ? const <api.ModulePermission>[]
        : [
            for (final perm in catalog)
              if (_matchesFilter(perm.name, perm.description)) perm,
          ];
    final nothingMatches =
        !showAdministrator && groups.isEmpty && modules.isEmpty;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(_inset, AppSpacing.s16, _inset, 0),
          child: AppInput(
            controller: _filter,
            placeholder: 'Filter permissions',
            icon: const Icon(AppIcons.search),
            semanticLabel: 'Filter permissions',
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (actionError case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _inset,
              AppSpacing.s12,
              _inset,
              0,
            ),
            child: AppErrorState(message: error, onDismiss: clearActionError),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(_inset, 0, _inset, 40),
            children: [
              if (nothingMatches)
                const SettingsEmptyState(
                  icon: AppIcons.search,
                  title: 'No permissions match',
                  detail: 'Try a different word.',
                ),
              if (showAdministrator)
                SettingsSectionCard(
                  children: [
                    PermissionToggleRow(
                      title: 'Administrator',
                      description: _administratorDescription,
                      semanticLabel: 'Administrator',
                      held: myPermissions.hasPermission(Perm.administrator),
                      value:
                          _bitOverrides[Perm.administrator] ??
                          held.hasPermission(Perm.administrator),
                      onChanged: (v) => _setBit(
                        Perm.administrator,
                        v,
                        held.hasPermission(Perm.administrator),
                      ),
                    ),
                  ],
                ),
              for (final (group, specs) in groups)
                SettingsSectionCard(
                  title: group.title,
                  children: [
                    for (final spec in specs)
                      PermissionToggleRow(
                        title: spec.label,
                        description: spec.description,
                        semanticLabel: spec.label,
                        elevated: spec.elevated,
                        held: myPermissions.hasPermission(spec.bit),
                        value:
                            _bitOverrides[spec.bit] ??
                            held.hasPermission(spec.bit),
                        onChanged: (v) =>
                            _setBit(spec.bit, v, held.hasPermission(spec.bit)),
                      ),
                  ],
                ),
              if (modules.isNotEmpty)
                SettingsSectionCard(
                  title: 'Modules',
                  children: [
                    for (final perm in modules) _moduleRow(perm, grantedKeys),
                  ],
                ),
            ],
          ),
        ),
        if (_pendingCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              _inset,
              0,
              _inset,
              AppSpacing.s16,
            ),
            child: SettingsSaveBar(
              changeCount: _pendingCount,
              saving: _saving,
              onDiscard: _discard,
              onSave: _save,
            ),
          ),
      ],
    );
  }

  Widget _moduleRow(api.ModulePermission perm, Set<String> grantedKeys) {
    final key = '${perm.moduleId}:${perm.permKey}';
    return PermissionToggleRow(
      title: perm.name,
      description: perm.description.isEmpty
          ? perm.moduleName
          : perm.description,
      semanticLabel: '${perm.name} (${perm.moduleName})',
      value: _moduleOverrides[key] ?? grantedKeys.contains(key),
      onChanged: (v) => _setModule(key, v, grantedKeys.contains(key)),
    );
  }
}
