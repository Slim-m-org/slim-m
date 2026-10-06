// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who may use a module, answered where the module is.
///
/// Installing a module registers its permissions into the role editor and
/// grants them to nobody - deliberately, per decision 0021, since installing
/// something is not a decision about who may use it. But an administrator who
/// installs a module and then finds it appears nowhere has no reason to guess
/// that a role grant is the missing step, and ADMINISTRATOR deliberately does
/// not bypass a module's own permission. So the question is asked here, right
/// after the install, and stays reachable from the module afterwards.
///
/// A routed screen, not a sheet, for the reason `dock_module_screen.dart`
/// already gives for itself: Space settings is a modal, the Dock and the
/// module screen are drill-downs inside it, and a sheet opened from the third
/// of those stacked a second scrim over a screen that was already dimming the
/// shell. Three levels deep is what the settings drill-down is for, so this is
/// the third level rather than an overlay on top of it.
///
/// One switch per role, covering every permission the module declares: a
/// module usually declares exactly one, and a role holding some but not all
/// of a multi-permission module's keys reads as off until it holds them all.
/// The per-key control still lives in the role editor for anyone who wants it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/app_launch.dart';
import '../../providers/code_block_runner.dart';
import '../../providers/providers.dart';
import '../../providers/slash_command.dart';
import '../../routing/routes.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_toggle_row.dart';
import '../settings_screen_scaffold.dart';

/// Resolves the manifest for [moduleId] so this screen can be deep-linked and
/// popped back to like any other, rather than needing its subject handed in.
class DockModuleAccessScreen extends ConsumerWidget {
  const DockModuleAccessScreen({
    super.key,
    required this.moduleId,
    this.source,
  });

  final String moduleId;

  /// The community source the module was installed from; null is official.
  final String? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = ref.watch(dockManifestFor(moduleId, source));
    return SettingsScreenScaffold(
      title: 'Who can use this',
      backTooltip: 'Back to the module',
      backFallback: Routes.adminDockModule(moduleId, source: source),
      child: AppAsyncView<api.DockManifest>(
        value: AppAsyncState(data: manifest.valueOrNull, error: manifest.error),
        center: false,
        errorMessage: 'Could not load this module.',
        onRetry: () => ref.invalidate(dockManifestFor(moduleId, source)),
        data: (context, m) => ModuleAccessPane(manifest: m),
      ),
    );
  }
}

/// The switches themselves, separate from the scaffold so the screen above
/// stays a routing shell and this stays testable on its own.
class ModuleAccessPane extends ConsumerStatefulWidget {
  const ModuleAccessPane({super.key, required this.manifest});

  final api.DockManifest manifest;

  @override
  ConsumerState<ModuleAccessPane> createState() => _ModuleAccessPaneState();
}

class _ModuleAccessPaneState extends ConsumerState<ModuleAccessPane>
    with GuardedActionState<ModuleAccessPane> {
  final Set<String> _pending = {};
  bool _busy = false;

  /// The module's own on/off switch, mirroring `dock_module_screen.dart`'s.
  /// Here so somebody who turned it on by granting a role can turn it back
  /// off without leaving, and so the state is never merely implied.
  Future<void> _setModuleEnabled(bool enabled) async {
    setState(() => _busy = true);
    final client = ref.read(apiProvider);
    final name = widget.manifest.name;
    final ok = await guard(
      whatFailed: enabled ? 'enable $name' : 'disable $name',
      action: () => enabled
          ? client.enableDockModule(widget.manifest.id)
          : client.disableDockModule(widget.manifest.id),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(dockCatalogProvider);
      ref.invalidate(codeBlockRunnerProvider);
      ref.invalidate(slashCommandProvider);
      ref.invalidate(appLaunchProvider);
    }
  }

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

  String _summary() {
    final names = [for (final p in widget.manifest.permissions) p.name];
    if (names.isEmpty) {
      return 'This module declares no permission of its own, so everyone who '
          'can see a channel can already use it.';
    }
    if (names.length == 1) return 'Grants "${names.single}".';
    return 'Grants ${names.length} permissions: ${names.join(', ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final roles = ref.watch(rolesProvider);

    final installed = ref
        .watch(dockCatalogProvider)
        .valueOrNull
        ?.installedFor(widget.manifest.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _summary(),
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: AppSpacing.s16),
        if (installed != null) ...[
          SettingsSectionCard(
            children: [
              SettingsToggleRow(
                label: widget.manifest.name,
                description: installed.enabled
                    ? 'Running in this space.'
                    : 'Off until you grant a role below.',
                semanticLabel: 'Run ${widget.manifest.name} in this space',
                value: installed.enabled,
                onChanged: _busy ? null : _setModuleEnabled,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s16),
          const SettingsSectionHeader('Who can use it'),
        ],
        AppAsyncView<List<api.Role>>(
          value: AppAsyncState(data: roles.valueOrNull, error: roles.error),
          center: false,
          errorMessage: 'Could not load the roles.',
          onRetry: () => ref.invalidate(rolesProvider),
          data: (context, list) => SettingsSectionCard(
            children: [
              for (final role in list)
                _RoleSwitch(
                  role: role,
                  busy: _pending.contains(role.id),
                  keysDeclared: _permKeys.isNotEmpty,
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

/// One role's switch, watching that role's own grants so a toggle reflects
/// what the server actually holds rather than what was tapped.
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
