// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module's full manifest, drilled into from [DockPane]: `GET
/// /space/dock/modules/{id}`, plus the install/enable/disable/uninstall
/// actions - `docs/decisions/0021-modules-and-the-dock.md`'s lifecycle on one
/// screen.
///
/// Everything a module will add is shown before an admin ever installs it:
/// the permissions it registers into the role editor and the host
/// capabilities it asks for, so approval happens with the whole picture in
/// view rather than after the fact.
///
/// A routed screen rather than a sheet: the Dock is itself a modal, and a
/// sheet opened from it stacked a second scrim and a second panel over the
/// first. This is the same drill-down every other settings screen uses, so
/// the way back is the app bar's own back arrow.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/admin_providers.dart';
import '../../providers/channel_permissions.dart'
    show myVisibleChannelsProvider;
import '../../features/modules/providers/app_launch.dart';
import '../../features/modules/providers/code_block_runner.dart';
import '../../features/composer/providers/slash_command.dart';
import '../../providers/providers.dart';
import '../../widgets/app_snackbar.dart';
import '../../widgets/confirm_dialog.dart';
import '../../routing/routes.dart';
import '../../widgets/run_guarded.dart';
import '../settings_screen_scaffold.dart';
import 'dock_module_view.dart';
import 'dock_host_access_card.dart';
import 'dock_install_consent.dart';

class DockModuleScreen extends ConsumerStatefulWidget {
  const DockModuleScreen({super.key, required this.moduleId, this.source});

  final String moduleId;

  /// The community source this module was opened from; null is the official
  /// one.
  final String? source;

  @override
  ConsumerState<DockModuleScreen> createState() => _DockModuleScreenState();
}

class _DockModuleScreenState extends ConsumerState<DockModuleScreen>
    with GuardedActionState<DockModuleScreen> {
  bool _busy = false;

  /// The switches the admin has flipped, or null to show what is installed.
  Set<String>? _hostApproved;

  /// What the switches show: the admin's edits, else what this space approved,
  /// limited to what [manifest] declares and the host can grant.
  Set<String> _approvedFor(
    api.DockManifest manifest,
    api.InstalledDockModule? installed,
  ) {
    final grantable = grantableHostCapabilities(manifest.capabilities);
    final carried = installed?.approvedHostCapabilities ?? const <String>[];
    final chosen = _hostApproved ?? carried;
    return {
      for (final capability in grantable)
        if (chosen.contains(capability) &&
            (_hostApproved != null ||
                !_needsReapproval(capability, manifest, installed)))
          capability,
    };
  }

  /// The second yes for the local network, null until the admin flips it.
  bool? _localNetwork;

  /// Whether the local network switch is on: only under an approved
  /// `net.fetch` on a manifest that asks, and never inherited by new hosts.
  bool _localFor(
    api.DockManifest manifest,
    api.InstalledDockModule? installed,
    Set<String> approved,
  ) {
    if (!(manifest.network?.local ?? false) ||
        !approved.contains('net.fetch')) {
      return false;
    }
    final carried =
        installed != null &&
        installed.localNetworkApproved &&
        dockSameHosts(installed.networkHosts, manifest.network!.hosts);
    return _localNetwork ?? carried;
  }

  /// A new build never inherits the power to post, and new hosts never inherit
  /// net.fetch: each has to be switched on again for what the admin is
  /// looking at.
  static bool _needsReapproval(
    String capability,
    api.DockManifest manifest,
    api.InstalledDockModule? installed,
  ) {
    if (installed == null) return false;
    return switch (capability) {
      'message.post' => installed.artifactSha256 != manifest.artifact.sha256,
      'net.fetch' => !dockSameHosts(
        installed.networkHosts,
        manifest.network?.hosts ?? const [],
      ),
      _ => false,
    };
  }

  List<String> _reapprovalsFor(
    api.DockManifest manifest,
    api.InstalledDockModule? installed,
  ) => [
    if (_hostApproved == null && installed != null)
      for (final c in installed.approvedHostCapabilities)
        if (_needsReapproval(c, manifest, installed)) c,
  ];

  void _toggleHostCapability(String capability, bool approved) {
    final installed = ref
        .read(dockCatalogProvider)
        .valueOrNull
        ?.installedFor(widget.moduleId);
    final manifest = ref
        .read(dockManifestFor(widget.moduleId, widget.source))
        .valueOrNull;
    if (manifest == null) return;
    setState(() {
      final next = {..._approvedFor(manifest, installed)};
      approved ? next.add(capability) : next.remove(capability);
      if (capability == 'net.fetch') _localNetwork = false;
      _hostApproved = next;
    });
  }

  /// Installs, or updates: the same call either way.
  ///
  /// Re-installing at a new version is what an update is here. The server
  /// upserts the row, leaves `enabled` alone, and only drops permission rows
  /// the new manifest no longer declares, so grants for surviving keys survive
  /// with it (`store/modules.rs`). There is deliberately no separate route.
  ///
  /// [wasInstalled] is why this takes an argument rather than reading the
  /// catalog again: only a first install should ask who may use the module.
  /// An update already has its answer, and throwing the admin at a screen full
  /// of switches they set last month would read as though it had been lost.
  Future<void> _install(
    api.DockManifest manifest, {
    bool wasInstalled = false,
  }) async {
    final current = ref
        .read(dockCatalogProvider)
        .valueOrNull
        ?.installedFor(manifest.id);
    final approved = _approvedFor(manifest, current);
    final asked = newConsentCapabilities(manifest, current);
    final verified = dockIsVerified(widget.source);
    if (dockNeedsConsent(
      newCapabilities: asked,
      verified: verified,
      firstInstall: !wasInstalled,
    )) {
      final agreed = await showDockInstallConsent(
        context,
        manifest: manifest,
        capabilities: asked,
        verified: verified,
        isUpdate: wasInstalled,
        localNetwork: _localFor(manifest, current, approved),
      );
      if (!agreed || !mounted) return;
    }
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: wasInstalled
          ? 'update ${manifest.name}'
          : 'install ${manifest.name}',
      action: () => ref
          .read(apiProvider)
          .installDockModule(
            moduleId: manifest.id,
            version: manifest.version,
            approvedHostCapabilities: approved.toList()..sort(),
            approveLocalNetwork: manifest.network == null
                ? null
                : _localFor(manifest, current, approved),
            source: widget.source,
          ),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _hostApproved = null;
        _localNetwork = null;
      }
    });
    if (!ok) return;
    showAppSnackbar(
      context,
      wasInstalled
          ? '${manifest.name} updated to v${manifest.version}'
          : '${manifest.name} installed',
    );
    ref.invalidate(dockCatalogProvider);
    ref.invalidate(modulePermissionsProvider);
    // A new version can declare different extension points; see this doc.
    ref.invalidate(codeBlockRunnerProvider);
    ref.invalidate(slashCommandProvider);
    ref.invalidate(appLaunchProvider);
    if (!wasInstalled && mounted) {
      // Installed is not usable until somebody is granted it; see that screen's doc.
      if (manifest.permissions.isNotEmpty) {
        unawaited(
          context.push(
            Routes.adminDockModuleAccess(manifest.id, source: widget.source),
          ),
        );
      } else {
        // Nothing to grant, so there is no later moment to turn it on at.
        await _setEnabled(manifest.name, true);
      }
    }
  }

  Future<void> _setEnabled(String name, bool enabled) async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: enabled ? 'enable $name' : 'disable $name',
      action: () => enabled
          ? ref.read(apiProvider).enableDockModule(widget.moduleId)
          : ref.read(apiProvider).disableDockModule(widget.moduleId),
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

  Future<void> _setScheduleChannel(String? channelId) async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'choose where ${widget.moduleId} posts',
      action: () => ref
          .read(apiProvider)
          .setDockModuleScheduleChannel(widget.moduleId, channelId),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(dockCatalogProvider);
  }

  Future<void> _uninstall(String name) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Uninstall $name?',
      message:
          'Removes it from this space along with every permission it '
          'registered and every role grant of them. This cannot be undone.',
      confirmLabel: 'Uninstall',
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'uninstall $name',
      action: () => ref.read(apiProvider).uninstallDockModule(widget.moduleId),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      ref.invalidate(dockCatalogProvider);
      ref.invalidate(modulePermissionsProvider);
      ref.invalidate(codeBlockRunnerProvider);
      ref.invalidate(slashCommandProvider);
      ref.invalidate(appLaunchProvider);
      // Back to the list: this module's own screen no longer describes anything installed.
      if (mounted) closeToDock(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = ref.watch(dockManifestFor(widget.moduleId, widget.source));
    final catalog = ref.watch(dockCatalogProvider).valueOrNull;
    final installed = catalog?.installedFor(widget.moduleId);
    final textChannels = [
      for (final c
          in ref.watch(myVisibleChannelsProvider).valueOrNull ??
              const <api.Channel>[])
        if (c.kind == 'text') c,
    ];
    final sourceRepo = widget.source == null
        ? null
        : catalog?.sections
                  .where((s) => s.source.id == widget.source)
                  .firstOrNull
                  ?.source
                  .repo ??
              installed?.sourceRepo;

    return SettingsScreenScaffold(
      title: manifest.valueOrNull?.name ?? 'Module',
      backTooltip: 'Back to Modules',
      backFallback: Routes.adminDock,
      child: AppAsyncView<api.DockManifest>(
        value: AppAsyncState(data: manifest.valueOrNull, error: manifest.error),
        center: false,
        errorMessage: 'Could not load this module.',
        onRetry: () =>
            ref.invalidate(dockManifestFor(widget.moduleId, widget.source)),
        data: (context, m) => DockManifestView(
          manifest: m,
          sourceRepo: sourceRepo,
          verified: dockIsVerified(widget.source),
          installed: installed,
          approvedHostCapabilities: _approvedFor(m, installed),
          reapprove: _reapprovalsFor(m, installed),
          localNetworkApproved: _localFor(
            m,
            installed,
            _approvedFor(m, installed),
          ),
          onLocalNetworkChanged: (v) => setState(() => _localNetwork = v),
          scheduleChannels: textChannels,
          onScheduleChannel: _setScheduleChannel,
          onToggleHostCapability: _toggleHostCapability,
          busy: _busy,
          error: actionError,
          onErrorDismiss: clearActionError,
          onInstall: () => _install(m, wasInstalled: installed != null),
          onSetEnabled: (v) => _setEnabled(m.name, v),
          onUninstall: () => _uninstall(m.name),
          onChooseAccess: () => context.push(
            Routes.adminDockModuleAccess(m.id, source: widget.source),
          ),
        ),
      ),
    );
  }
}

/// Leaves a module's screen for the list it was opened from, falling back to
/// the Dock's own route when there is nothing to pop (a cold deep link).
void closeToDock(BuildContext context) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) {
    navigator.pop();
  } else {
    GoRouter.of(context).go(Routes.adminDock);
  }
}
