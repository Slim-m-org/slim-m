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

import '../../permissions.dart';
import '../../providers/admin_providers.dart';
import '../../providers/app_launch.dart';
import '../../providers/code_block_runner.dart';
import '../../providers/providers.dart';
import '../../providers/slash_command.dart';
import '../../widgets/run_guarded.dart';
import 'role_permissions_rows.dart';

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
    final tokens = Theme.of(context).extension<AppTokens>()!;
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

    final showAdministrator = _matchesFilter(
      'Administrator',
      'Every permission below, in every channel, ignoring overrides.',
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s8,
          ),
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
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
            child: AppErrorState(message: error, onDismiss: clearActionError),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            children: [
              if (showAdministrator)
                AdministratorRow(
                  value:
                      _bitOverrides[Perm.administrator] ??
                      widget.role.permissions.hasPermission(Perm.administrator),
                  dimmed: !myPermissions.hasPermission(Perm.administrator),
                  onChanged: myPermissions.hasPermission(Perm.administrator)
                      ? (v) => _setBit(
                          Perm.administrator,
                          v,
                          widget.role.permissions.hasPermission(
                            Perm.administrator,
                          ),
                        )
                      : null,
                ),
              for (final group in Perm.groups) ...[
                if (group.permissions.any(
                  (s) => _matchesFilter(s.label, s.description),
                ))
                  GroupHeader(title: group.title),
                for (final spec in group.permissions)
                  if (_matchesFilter(spec.label, spec.description))
                    PermissionListRow(
                      spec: spec,
                      value:
                          _bitOverrides[spec.bit] ??
                          widget.role.permissions.hasPermission(spec.bit),
                      allowed: myPermissions.hasPermission(spec.bit),
                      onChanged: (v) => _setBit(
                        spec.bit,
                        v,
                        widget.role.permissions.hasPermission(spec.bit),
                      ),
                    ),
              ],
              if (catalog.isNotEmpty && granted != null) ...[
                if (catalog.any((p) => _matchesFilter(p.name, p.description)))
                  const GroupHeader(title: 'Modules'),
                for (final perm in catalog)
                  if (_matchesFilter(perm.name, perm.description))
                    ModulePermissionListRow(
                      permission: perm,
                      value:
                          _moduleOverrides['${perm.moduleId}:${perm.permKey}'] ??
                          grantedKeys.contains(
                            '${perm.moduleId}:${perm.permKey}',
                          ),
                      onChanged: (v) => _setModule(
                        '${perm.moduleId}:${perm.permKey}',
                        v,
                        grantedKeys.contains(
                          '${perm.moduleId}:${perm.permKey}',
                        ),
                      ),
                    ),
              ],
            ],
          ),
        ),
        if (_pendingCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.surfaceBase,
                border: Border.all(color: tokens.borderSubtle),
                borderRadius: BorderRadius.circular(AppRadii.card),
                boxShadow: AppShadows.float,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s16,
                  AppSpacing.s8,
                  AppSpacing.s8,
                  AppSpacing.s8,
                ),
                child: Row(
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.accent,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(width: 6, height: 6),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Expanded(
                      child: Text(
                        '$_pendingCount unsaved ${_pendingCount == 1 ? 'change' : 'changes'}',
                        style: AppText.ui.copyWith(color: tokens.textPrimary),
                      ),
                    ),
                    AppButton(
                      label: 'Discard',
                      variant: AppButtonVariant.ghost,
                      size: AppButtonSize.sm,
                      disabled: _saving,
                      onPressed: _discard,
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    AppButton(
                      label: _saving ? 'Saving...' : 'Save changes',
                      variant: AppButtonVariant.primary,
                      size: AppButtonSize.sm,
                      disabled: _saving,
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
