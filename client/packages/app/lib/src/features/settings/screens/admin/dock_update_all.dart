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

/// An installed module that has an update, and the community source to install
/// it from (null for the official one).
typedef DockOutdated = ({api.DockIndexEntry entry, String? source});

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

/// How the walk went, for the line under the Update all bar and the error box.
class DockUpdateReport {
  const DockUpdateReport({
    required this.total,
    required this.updated,
    required this.skipped,
    required this.failures,
  });

  final int total;
  final int updated;

  /// Modules the admin skipped, which keep their update.
  final List<api.DockIndexEntry> skipped;

  /// One sentence per install that failed, with the reason.
  final List<String> failures;

  /// The neutral line after a walk that left something undone, or null.
  ///
  /// Only skipped modules still behind are named: one updated from its own page
  /// since is not "skipped" any more.
  String? summary(List<DockOutdated> stillOutdated) {
    final behind = {for (final o in stillOutdated) o.entry.id};
    final skippedNow = [
      for (final entry in skipped)
        if (behind.contains(entry.id)) entry.name,
    ];
    if (skippedNow.isEmpty && failures.isEmpty) return null;
    return [
      'Updated $updated of $total.',
      if (skippedNow.isNotEmpty) 'Skipped ${skippedNow.join(', ')}.',
    ].join(' ');
  }
}

enum _Outcome { updated, skipped, failed }

typedef _Turn = ({_Outcome outcome, String? failure});

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
  final client = ref.read(apiProvider);
  final catalog = ref.read(dockCatalogProvider).valueOrNull;
  var updated = 0;
  final skipped = <api.DockIndexEntry>[];
  final failures = <String>[];
  for (final item in outdated) {
    final turn = await _updateOne(
      context,
      client,
      item,
      catalog?.installedFor(item.entry.id),
    );
    if (turn == null || !context.mounted) return null;
    switch (turn.outcome) {
      case _Outcome.skipped:
        skipped.add(item.entry);
      case _Outcome.failed:
        failures.add(turn.failure!);
      case _Outcome.updated:
        updated++;
        _refreshAfterInstall(ref);
    }
  }
  return DockUpdateReport(
    total: outdated.length,
    updated: updated,
    skipped: skipped,
    failures: failures,
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

/// One module's turn, or null when [context] went away while it was asked.
Future<_Turn?> _updateOne(
  BuildContext context,
  api.SlimmApi client,
  DockOutdated item,
  api.InstalledDockModule? current,
) async {
  try {
    final manifest = await client.getDockModule(
      item.entry.id,
      source: item.source,
    );
    if (!context.mounted) return null;
    final ask = dockUpdateAsk(manifest, current);
    Set<String>? approved;
    if (ask.capabilities.isNotEmpty) {
      final agreed = await _askAbout(context, item, manifest, current, ask);
      if (!context.mounted) return null;
      if (!agreed) return (outcome: _Outcome.skipped, failure: null);
      approved = {..._carried(manifest, current), ...ask.capabilities};
    }
    final installed = await _install(client, item, manifest, current, approved);
    if (!context.mounted) return null;
    final lost = approved == null
        ? _lostAccess(manifest, current, installed)
        : const <String>[];
    if (lost.isNotEmpty) {
      final again = (capabilities: lost, reapproveOnly: true);
      final agreed = await _askAbout(context, item, manifest, current, again);
      if (!context.mounted) return null;
      if (agreed) {
        final regained = {...installed.approvedHostCapabilities, ...lost};
        await _install(client, item, manifest, current, regained);
      }
    }
    return (outcome: _Outcome.updated, failure: null);
  } catch (error, stack) {
    return (
      outcome: _Outcome.failed,
      failure: reportFailureSentence(
        api.LogTag.ui,
        'update ${item.entry.name}',
        error,
        stack,
      ),
    );
  }
}

Future<bool> _askAbout(
  BuildContext context,
  DockOutdated item,
  api.DockManifest manifest,
  api.InstalledDockModule? current,
  DockUpdateAsk ask,
) => showDockInstallConsent(
  context,
  manifest: manifest,
  capabilities: ask.capabilities,
  verified: dockIsVerified(item.source),
  isUpdate: true,
  reapprove: ask.reapproveOnly,
  changes: dockConsentChanges(manifest, current),
  confirmLabel: 'Approve and update',
  cancelLabel: 'Skip',
);

/// Installs [item]'s offered version. [approved] null lets the server carry
/// what the module held, and a set replaces it with what the admin was shown.
Future<api.InstalledDockModule> _install(
  api.SlimmApi client,
  DockOutdated item,
  api.DockManifest manifest,
  api.InstalledDockModule? current,
  Set<String>? approved,
) => client.installDockModule(
  moduleId: item.entry.id,
  version: item.entry.version,
  approvedHostCapabilities: approved == null
      ? null
      : (approved.toList()..sort()),
  approveLocalNetwork: approved == null || manifest.network == null
      ? null
      : dockLocalNetworkCarries(manifest, current, approved),
  reviewedDigest: manifest.reviewDigest,
  source: item.source,
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

/// Access the server withdrew from [before] that [manifest] still declares.
///
/// The client's carry rules mirror the server's, so this is the rare change it
/// could not see coming, such as a hook that widened without a new build.
List<String> _lostAccess(
  api.DockManifest manifest,
  api.InstalledDockModule? before,
  api.InstalledDockModule installed,
) => [
  for (final capability in before?.approvedHostCapabilities ?? const <String>[])
    if (manifest.capabilities.contains(capability) &&
        !installed.approvedHostCapabilities.contains(capability))
      capability,
];
