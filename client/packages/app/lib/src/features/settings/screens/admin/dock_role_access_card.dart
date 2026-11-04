// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who may use a module, answered where the module is: the Access tab.
///
/// Installing a module registers its permissions into the role editor and
/// grants them to nobody - deliberately, per decision 0021, since installing
/// something is not a decision about who may use it. But an administrator who
/// installs a module and then finds it appears nowhere has no reason to guess
/// that a role grant is the missing step, and ADMINISTRATOR deliberately does
/// not bypass a module's own permission. So the first install lands on the
/// Access tab, and the question stays reachable from there.
///
/// One switch per role, covering every permission the module declares: a
/// module usually declares exactly one, and a role holding some but not all
/// of a multi-permission module's keys reads as off until it holds them all.
/// The per-key control still lives in the role editor for anyone who wants it.
/// Each switch applies at once; it is not part of the tab's Save.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../modules/providers/app_launch.dart';
import '../../../modules/providers/code_block_runner.dart';
import '../../../../providers/providers.dart';
import '../../../composer/providers/slash_command.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_info_line.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';

/// The switches themselves, one per role.
class DockRoleAccessCard extends ConsumerStatefulWidget {
  const DockRoleAccessCard({super.key, required this.manifest});

  final api.DockManifest manifest;

  @override
  ConsumerState<DockRoleAccessCard> createState() => _DockRoleAccessCardState();
}

class _DockRoleAccessCardState extends ConsumerState<DockRoleAccessCard>
    with GuardedActionState<DockRoleAccessCard> {
  final Set<String> _pending = {};

  List<String> get _permKeys => [
    for (final p in widget.manifest.permissions) p.key,
  ];

  /// Whether a role holding [granted] holds every key this module declares.
  bool _holdsAll(List<api.GrantedModulePermission> granted) {
    final held = {
      for (final g in granted)
        if (g.moduleId == widget.manifest.id) g.permKey,
    };
    return _permKeys.isNotEmpty && _permKeys.every(held.contains);
  }

  Future<void> _set(api.Role role, bool value) async {
    setState(() => _pending.add(role.id));
    final client = ref.read(apiProvider);
    final ok = await guard(
      whatFailed: value
          ? 'give ${role.name} access to ${widget.manifest.name}'
          : 'take ${widget.manifest.name} away from ${role.name}',
      action: () async {
        for (final key in _permKeys) {
          if (value) {
            await client.grantModulePermission(
              roleId: role.id,
              moduleId: widget.manifest.id,
              permKey: key,
            );
          } else {
            await client.revokeModulePermission(
              roleId: role.id,
              moduleId: widget.manifest.id,
              permKey: key,
            );
          }
        }
      },
    );
    if (!mounted) return;
    setState(() => _pending.remove(role.id));
    // A half-applied change leaves the server holding something in between.
    ref.invalidate(roleModulePermissionsProvider(role.id));
    if (ok && value) await _enableIfOff();
    if (!mounted) return;
    // Invalidated after the enable, so the refetch sees the module as on.
    ref.invalidate(codeBlockRunnerProvider);
    ref.invalidate(slashCommandProvider);
    ref.invalidate(appLaunchProvider);
  }

  /// Turns the module on the first time somebody is granted it.
  ///
  /// An install lands disabled on purpose (decision 0021: installing is not a
  /// decision about who may use it), and granting a role is exactly that
  /// decision, so it is the honest moment to act on it. Without this the
  /// admin closes this screen with the module installed, granted and still
  /// off - the same "no reason to guess a step is missing" trap this screen
  /// exists to close, one step further along.
  ///
  /// Only ever on. Revoking the last grant does not disable it, because a
  /// module that is off and a module nobody holds are different states and
  /// an admin may be mid-reshuffle.
  Future<void> _enableIfOff() async {
    final installed = ref
        .read(dockCatalogProvider)
        .valueOrNull
        ?.installedFor(widget.manifest.id);
    if (installed == null || installed.enabled) return;
    final ok = await guard(
      whatFailed: 'enable ${widget.manifest.name}',
      action: () => ref.read(apiProvider).enableDockModule(widget.manifest.id),
    );
    if (ok && mounted) ref.invalidate(dockCatalogProvider);
  }

  @override
  Widget build(BuildContext context) {
    final roles = ref.watch(rolesProvider);
    if (widget.manifest.permissions.isEmpty) {
      return const SettingsSectionCard(
        title: 'Who can use it',
        children: [
          SettingsInfoLine(
            'No permission of its own. Anyone who can see a '
            'channel can use it.',
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppAsyncView<List<api.Role>>(
          value: AppAsyncState(data: roles.valueOrNull, error: roles.error),
          center: false,
          errorMessage: 'Could not load the roles.',
          onRetry: () => ref.invalidate(rolesProvider),
          data: (context, list) => SettingsSectionCard(
            title: 'Who can use it',
            description: 'Applies as you switch.',
            children: [
              for (final role in list)
                _RoleSwitch(
                  role: role,
                  busy: _pending.contains(role.id),
                  keysDeclared: true,
                  holdsAll: _holdsAll,
                  onChanged: (value) => _set(role, value),
                ),
            ],
          ),
        ),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}

class _RoleSwitch extends ConsumerWidget {
  const _RoleSwitch({
    required this.role,
    required this.busy,
    required this.keysDeclared,
    required this.holdsAll,
    required this.onChanged,
  });

  final api.Role role;
  final bool busy;
  final bool keysDeclared;
  final bool Function(List<api.GrantedModulePermission>) holdsAll;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final granted = ref.watch(roleModulePermissionsProvider(role.id));
    final ready = granted.hasValue && !busy && keysDeclared;
    return SettingsToggleRow(
      label: role.name,
      semanticLabel: 'Let ${role.name} use this module',
      value: holdsAll(granted.valueOrNull ?? const []),
      onChanged: ready ? onChanged : null,
    );
  }
}
