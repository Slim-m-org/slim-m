// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Update all: walks the outdated modules in order and installs each one.
/// A module that asks for access gets the consent step first, and the admin
/// approves it or skips it (docs/decisions/0067-module-install-consent.md).
///
/// The step is `showAppSheet`, a sheet on a phone and a dialog on a desktop
/// (docs/design/desktop-vs-mobile.md, rule 4: a short task with a submit).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../../api_failure.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../composer/providers/slash_command.dart';
import '../../../modules/providers/app_launch.dart';
import '../../../modules/providers/code_block_runner.dart';
import 'dock_host_access_card.dart';
import 'dock_install_consent.dart';
import 'dock_update_report.dart';

/// What an update has to ask the admin before it installs.
///
/// [reapproveOnly] is an update that asks for nothing new and only takes back
/// access the module held, which a new build does to `message.post`.
typedef DockUpdateAsk = ({List<String> capabilities, bool reapproveOnly});

/// The access [manifest] asks for that [installed] does not already hold:
/// declared for the first time, widened, or approved before and taken back.
DockUpdateAsk dockUpdateAsk(
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) {
  final fresh = newConsentCapabilities(manifest, installed);
  final heldBefore = installed?.approvedHostCapabilities ?? const <String>[];
  final takenBack = {
    for (final capability in grantableHostCapabilities(manifest.capabilities))
      if (heldBefore.contains(capability) &&
          dockNeedsReapproval(capability, manifest, installed))
        capability,
  };
  return (
    capabilities: [
      for (final capability in grantableHostCapabilities(manifest.capabilities))
        if (fresh.contains(capability) || takenBack.contains(capability))
          capability,
    ],
    reapproveOnly: fresh.isEmpty,
  );
}

enum _Outcome { updated, skipped, failed }

class _Turn {
  const _Turn(this.outcome, {this.failure, this.declined = const []});

  final _Outcome outcome;
  final String? failure;

  /// Access the server withdrew after the update that the admin did not give back.
  final List<String> declined;
}

/// The access an install replaces what the module held with, and whether the
/// private-network yes goes with it.
typedef _Grant = ({Set<String> host, bool localNetwork});

/// Updates [outdated] one at a time, the sequence that keeps a partial result
/// easy to explain: each install is a write against one space.
///
/// Returns null when [context] went away mid-walk, since nothing can be asked
/// then and the rest stay for the next press.
Future<DockUpdateReport?> updateAllDockModules({
  required BuildContext context,
  required WidgetRef ref,
  required List<DockOutdated> outdated,
}) async {
  var updated = 0;
  final skipped = <api.DockIndexEntry>[];
  final failures = <String>[];
  final withoutAccess = <DockLeftBare>[];
  for (final item in outdated) {
    final turn = await _updateOne(context, ref, item);
    if (turn == null || !context.mounted) return null;
    switch (turn.outcome) {
      case _Outcome.skipped:
        skipped.add(item.entry);
      case _Outcome.failed:
        failures.add(turn.failure!);
      case _Outcome.updated:
        updated++;
        if (turn.declined.isNotEmpty) {
          withoutAccess.add((entry: item.entry, lost: turn.declined));
        }
    }
  }
  ref.invalidate(dockCatalogProvider);
  return DockUpdateReport(
    total: outdated.length,
    updated: updated,
    skipped: skipped,
    failures: failures,
    withoutAccess: withoutAccess,
  );
}

/// The same set a per-module install invalidates: a version can declare different extension points.
void _refreshAfterInstall(WidgetRef ref) {
  ref.invalidate(dockCatalogProvider);
  ref.invalidate(modulePermissionsProvider);
  ref.invalidate(codeBlockRunnerProvider);
  ref.invalidate(slashCommandProvider);
  ref.invalidate(appLaunchProvider);
}

/// The record the server holds for [moduleId] now, or null once it is gone.
/// Read per step because access is revoked while the walk waits on an admin.
Future<api.InstalledDockModule?> _heldNow(
  WidgetRef ref,
  String moduleId,
) async {
  final installed = await ref.read(apiProvider).listInstalledDockModules();
  return installed.where((m) => m.id == moduleId).firstOrNull;
}

/// One module's turn, or null when [context] went away while it was asked.
/// A module removed since the walk began is left removed.
Future<_Turn?> _updateOne(
  BuildContext context,
  WidgetRef ref,
  DockOutdated item,
) async {
  try {
    final current = await _heldNow(ref, item.entry.id);
    if (current == null) return const _Turn(_Outcome.skipped);
    final manifest = await ref
        .read(apiProvider)
        .getDockModule(item.entry.id, source: item.source);
    if (!context.mounted) return null;
    final ask = dockUpdateAsk(manifest, current);
    _Grant? grant;
    if (ask.capabilities.isNotEmpty) {
      final agreed = await _askAbout(context, item, manifest, current, ask);
      if (!context.mounted) return null;
      if (!agreed) return const _Turn(_Outcome.skipped);
      final held = await _heldNow(ref, item.entry.id);
      if (!context.mounted) return null;
      if (held == null) return const _Turn(_Outcome.skipped);
      grant = _grantFor(manifest, held, {
        ..._carried(manifest, held),
        ...ask.capabilities,
      }, ask.capabilities);
    }
    final installed = await _install(context, ref, item, manifest, grant);
    if (!context.mounted) return null;
    final lost = grant == null
        ? _lostAccess(manifest, current, installed)
        : const <String>[];
    if (lost.isEmpty) return const _Turn(_Outcome.updated);
    final again = (capabilities: lost, reapproveOnly: true);
    final agreed = await _askAbout(
      context,
      item,
      manifest,
      current,
      again,
      updated: true,
    );
    if (!context.mounted) return null;
    if (!agreed) return _Turn(_Outcome.updated, declined: lost);
    final held = await _heldNow(ref, item.entry.id);
    if (!context.mounted) return null;
    if (held != null) {
      final regained = {...held.approvedHostCapabilities, ...lost};
      final grant = _grantFor(manifest, held, regained, lost);
      await _install(context, ref, item, manifest, grant);
    }
    return const _Turn(_Outcome.updated);
  } catch (error, stack) {
    return _Turn(
      _Outcome.failed,
      failure: reportFailureSentence(
        api.LogTag.ui,
        'update ${item.entry.name}',
        error,
        stack,
      ),
    );
  }
}

/// The consent step for [ask]. With [updated] the install already happened and
/// the step asks whether to give back access it took away.
Future<bool> _askAbout(
  BuildContext context,
  DockOutdated item,
  api.DockManifest manifest,
  api.InstalledDockModule? current,
  DockUpdateAsk ask, {
  bool updated = false,
}) => showDockInstallConsent(
  context,
  manifest: manifest,
  capabilities: ask.capabilities,
  verified: dockIsVerified(item.source),
  isUpdate: true,
  title: updated ? '${manifest.name} is updated. Give back its access?' : null,
  intro: switch ((updated, ask.reapproveOnly)) {
    (true, _) => 'The update took this access back. It can:',
    (_, true) => 'This version needs approval again. It can:',
    _ => null,
  },
  changes: dockConsentChanges(manifest, current),
  confirmLabel: updated ? 'Give access back' : 'Approve and update',
  cancelLabel: updated ? 'Leave it off' : 'Skip',
);

/// Installs [item]'s offered version, then reads the module list again: the
/// server may have committed even when the answer was an error.
///
/// A null [grant] lets the server carry what the module held, and a set
/// replaces it with what the admin was shown.
Future<api.InstalledDockModule> _install(
  BuildContext context,
  WidgetRef ref,
  DockOutdated item,
  api.DockManifest manifest,
  _Grant? grant,
) async {
  try {
    return await ref
        .read(apiProvider)
        .installDockModule(
          moduleId: item.entry.id,
          version: item.entry.version,
          approvedHostCapabilities: grant == null
              ? null
              : (grant.host.toList()..sort()),
          approveLocalNetwork: grant == null || manifest.network == null
              ? null
              : grant.localNetwork,
          reviewedDigest: manifest.reviewDigest,
          source: item.source,
        );
  } finally {
    if (context.mounted) _refreshAfterInstall(ref);
  }
}

/// [approved] with the private-network yes [held] gave, when it still stands.
///
/// It carries only while net.fetch itself does: when the step [asked] about
/// net.fetch, the prompt never showed the yes, so it goes back to the module's
/// own switch as it does for a single update.
_Grant _grantFor(
  api.DockManifest manifest,
  api.InstalledDockModule? held,
  Set<String> approved,
  List<String> asked,
) => (
  host: approved,
  localNetwork: dockLocalNetworkCarries(
    manifest,
    held,
    approved.difference(asked.toSet()),
  ),
);

/// What [current] approved that the new build keeps without asking again.
Set<String> _carried(
  api.DockManifest manifest,
  api.InstalledDockModule? current,
) {
  final grantable = grantableHostCapabilities(manifest.capabilities);
  return {
    for (final capability
        in current?.approvedHostCapabilities ?? const <String>[])
      if (grantable.contains(capability) &&
          !dockNeedsReapproval(capability, manifest, current))
        capability,
  };
}

/// What a carrying install withdrew from [before] that this client can show.
/// A list the admin was shown is applied as sent, so it withdraws nothing.
List<String> _lostAccess(
  api.DockManifest manifest,
  api.InstalledDockModule? before,
  api.InstalledDockModule installed,
) => [
  for (final capability in grantableHostCapabilities(manifest.capabilities))
    if ((before?.approvedHostCapabilities.contains(capability) ?? false) &&
        !installed.approvedHostCapabilities.contains(capability))
      capability,
];
