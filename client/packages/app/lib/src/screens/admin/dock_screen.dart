// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock: browsing and installing modules from the addons marketplace.
/// `GET /space/dock/modules` and `GET /space/dock/installed`. Requires
/// MANAGE_SERVER, the same bit `/space/settings` and every other pane in this
/// directory already require.
///
/// Read-only itself: opening a row is what leads to install, enable/disable
/// and uninstall, all on the module's own screen - see
/// `docs/decisions/0021-modules-and-the-dock.md`'s lifecycle. This mirrors
/// `analytics_screen.dart`/`storage_screen.dart`'s own shape: a scaffold plus
/// an `AppAsyncView` over a Space settings pane.
library;

import 'dart:async';

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
import '../../widgets/confirm_dialog.dart';
import '../../widgets/ring_flush.dart';
import '../../widgets/run_guarded.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'dock_module_row.dart';
import 'dock_sources_section.dart';

class DockScreen extends StatelessWidget {
  const DockScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Dock',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: DockPane(),
  );
}

/// An installed module that has an update, and the community source to install
/// it from (null for the official one).
typedef _Outdated = ({api.DockIndexEntry entry, String? source});

/// The host capability a new build of a module has to be approved for again.
const _postMessages = 'message.post';

/// The module list itself, embeddable as a Space settings pane as well as
/// routed.
class DockPane extends ConsumerStatefulWidget {
  const DockPane({super.key});

  @override
  ConsumerState<DockPane> createState() => _DockPaneState();
}

class _DockPaneState extends ConsumerState<DockPane>
    with GuardedActionState<DockPane> {
  final _query = TextEditingController();

  /// True while [_updateAll] is working through the outdated modules, so the
  /// button cannot be pressed twice and says what it is doing.
  bool _updatingAll = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Name, id and summary, so a search for what a module *does* finds it and
  /// not only one for what it is called.
  bool _matches(api.DockIndexEntry entry, String needle) =>
      entry.name.toLowerCase().contains(needle) ||
      entry.id.toLowerCase().contains(needle) ||
      entry.summary.toLowerCase().contains(needle);

  /// Every installed module its own source now lists a different version of.
  ///
  /// Different rather than newer: the registry is the authority on what a
  /// space may install, and comparing semver here would invent an opinion the
  /// install route does not share (it refuses anything but the current
  /// manifest, see `installDockModule`). A rolled-back registry is therefore
  /// an update too, which is the honest reading of "match the marketplace".
  ///
  /// Community sources count the same way their rows' badges do: a module is
  /// outdated in a source only if it was installed from that very source, and
  /// it is updated from there.
  static List<_Outdated> _outdated(DockCatalog catalog) => [
    for (final entry in catalog.entries)
      if (catalog.installedFor(entry.id) case final installed?)
        if (installed.sourceRepo == null && installed.version != entry.version)
          (entry: entry, source: null),
    for (final section in catalog.sections)
      if (!section.failed)
        for (final entry in section.entries)
          if (catalog.installedFor(entry.id) case final installed?)
            if (installed.sourceRepo == section.source.repo &&
                installed.version != entry.version)
              (entry: entry, source: section.source.id),
  ];

  /// Updates every outdated module, one at a time, and reports what did not
  /// take rather than stopping at the first failure.
  ///
  /// Sequential on purpose: each install is a write against one space, and a
  /// partial result is much easier to explain ("two of five updated") than a
  /// burst that raced. Nothing navigates afterwards - an update already knows
  /// who may use the module, which is why the per-module screen only sends a
  /// *first* install to the access screen.
  ///
  /// A new build drops the approval to post messages (`message.post`), since
  /// what was approved was the old build, so the modules that lost it are
  /// named: decision 0023 says the Dock tells you on the update screen.
  Future<void> _updateAll(List<_Outdated> outdated) async {
    clearActionError();
    setState(() => _updatingAll = true);
    final failed = <String>[];
    final needApproval = <String>[];
    for (final (:entry, :source) in outdated) {
      final before = ref
          .read(dockCatalogProvider)
          .valueOrNull
          ?.installedFor(entry.id)
          ?.approvedHostCapabilities;
      try {
        final updated = await ref
            .read(apiProvider)
            .installDockModule(
              moduleId: entry.id,
              version: entry.version,
              source: source,
            );
        if ((before?.contains(_postMessages) ?? false) &&
            !updated.approvedHostCapabilities.contains(_postMessages)) {
          needApproval.add(entry.name);
        }
      } catch (_) {
        failed.add(entry.name);
      }
    }
    if (!mounted) return;
    setState(() => _updatingAll = false);
    // The same set a per-module install invalidates: a version can declare different extension points.
    ref.invalidate(dockCatalogProvider);
    ref.invalidate(modulePermissionsProvider);
    ref.invalidate(codeBlockRunnerProvider);
    ref.invalidate(slashCommandProvider);
    ref.invalidate(appLaunchProvider);
    if (failed.isEmpty && needApproval.isEmpty) return;
    final updated = outdated.length - failed.length;
    setActionError(
      [
        'Updated $updated of ${outdated.length}.',
        if (failed.isNotEmpty) 'Could not update ${failed.join(', ')}.',
        if (needApproval.isNotEmpty)
          '${needApproval.join(', ')} needs Post messages approved again.',
      ].join(' '),
    );
  }

  Future<void> _removeSource(api.DockSource source) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Remove ${source.repo}?',
      message:
          'Modules already installed from it stay installed and enabled, but '
          'they cannot be updated until you add this source again.',
      confirmLabel: 'Remove source',
    );
    if (!confirmed || !mounted) return;
    final ok = await guard(
      whatFailed: 'remove ${source.repo}',
      action: () => ref.read(apiProvider).removeDockSource(source.id),
    );
    if (ok && mounted) ref.invalidate(dockCatalogProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final catalog = ref.watch(dockCatalogProvider);
    final needle = _query.text.trim().toLowerCase();
    return AppAsyncView<DockCatalog>(
      value: AppAsyncState(data: catalog.valueOrNull, error: catalog.error),
      center: false,
      errorMessage: 'Could not reach the module marketplace.',
      onRetry: () => ref.invalidate(dockCatalogProvider),
      // No section title: this screen is one group, matching Roles' own choice.
      data: (context, catalog) {
        final shown = [
          for (final entry in catalog.entries)
            if (needle.isEmpty || _matches(entry, needle)) entry,
        ];
        final outdated = _outdated(catalog);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (actionError case final message?) ...[
              AppErrorState(message: message, onDismiss: clearActionError),
              const SizedBox(height: AppSpacing.s12),
            ],
            if (outdated.isNotEmpty) ...[
              _UpdateAllBar(
                count: outdated.length,
                busy: _updatingAll,
                onUpdateAll: () => unawaited(_updateAll(outdated)),
              ),
              const SizedBox(height: AppSpacing.s12),
            ],
            RingFlush(
              child: AppInput(
                controller: _query,
                placeholder: 'Search modules',
                semanticLabel: 'Search modules',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Text(
                  catalog.entries.isEmpty
                      ? 'No modules are published in the marketplace yet.'
                      : 'No module matches "${_query.text.trim()}".',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                ),
              )
            else
              SettingsSectionCard(
                title: catalog.sections.isEmpty ? null : 'Official modules',
                children: [
                  for (final entry in shown)
                    DockModuleRow(
                      entry: entry,
                      installed: catalog.installedFor(entry.id),
                    ),
                ],
              ),
            for (final section in catalog.sections)
              DockCommunitySection(
                section: section,
                catalog: catalog,
                needle: needle,
                onRemove: () => unawaited(_removeSource(section.source)),
              ),
            if (catalog.sourcesFailed) ...[
              const SizedBox(height: AppSpacing.s12),
              const AppErrorState(
                message: 'Could not load the community sources.',
              ),
            ],
            const SizedBox(height: AppSpacing.s16),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: 'Add a community source',
                icon: AppIcons.add,
                onPressed: () => unawaited(showAddDockSourceSheet(context)),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Offers one press for every module this space is behind the marketplace on.
///
/// Above the search box rather than in it: filtering the list must not change
/// what "update all" means, and a bar that moved or changed its count as you
/// typed would imply it does.
class _UpdateAllBar extends StatelessWidget {
  const _UpdateAllBar({
    required this.count,
    required this.busy,
    required this.onUpdateAll,
  });

  final int count;
  final bool busy;
  final VoidCallback onUpdateAll;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final subject = count == 1 ? '1 module has' : '$count modules have';
    return SettingsSectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s8,
            vertical: AppSpacing.s4,
          ),
          child: Row(
            children: [
              Icon(AppIcons.dock, color: tokens.accent),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: Text(
                  '$subject an update',
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              AppButton(
                label: busy ? 'Updating...' : 'Update all',
                variant: AppButtonVariant.primary,
                size: AppButtonSize.sm,
                disabled: busy,
                onPressed: onUpdateAll,
                semanticLabel: 'Update all modules',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
