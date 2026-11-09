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

import '../../../../providers/admin_providers.dart';
import '../../../../routing/routes.dart';
import '../../../voice/widgets/ring_flush.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_empty.dart';
import '../../widgets/settings_section_header.dart';
import '../settings_screen_scaffold.dart';
import 'dock_file_install.dart';
import 'dock_manage_sources.dart';
import 'dock_module_row.dart';
import 'dock_pane_header.dart';
import 'dock_sources_section.dart';
import 'dock_update_all.dart';

class DockScreen extends StatelessWidget {
  const DockScreen({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreenScaffold(
    title: 'Modules',
    backTooltip: 'Back to Space settings',
    backFallback: Routes.spaceSettings,
    child: DockPane(),
  );
}

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

  /// Null until the admin picks one; then Installed if anything is, else Browse.
  DockListFilter? _filter;

  /// True while [_updateAll] is working through the outdated modules, so the
  /// button cannot be pressed twice and says what it is doing.
  bool _updatingAll = false;

  /// How the last Update all went, until the next one starts.
  DockUpdateReport? _updateReport;

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
  static List<DockOutdated> _outdated(DockCatalog catalog) => [
    for (final entry in catalog.entries)
      if (_isBehind(catalog, entry, null)) (entry: entry, source: null),
    for (final section in catalog.sections)
      if (!section.failed)
        for (final entry in section.entries)
          if (_isBehind(catalog, entry, section.source.repo))
            (entry: entry, source: section.source.id),
  ];

  /// Installed from [repo] (null for the official source) at another version.
  static bool _isBehind(
    DockCatalog catalog,
    api.DockIndexEntry entry,
    String? repo,
  ) {
    final installed = catalog.installedFor(entry.id);
    return installed != null &&
        installed.sourceRepo == repo &&
        installed.version != entry.version;
  }

  /// Walks the outdated modules, asking about the ones that want new access,
  /// and keeps going past a skip or a failure so one module cannot stop the rest.
  ///
  /// A module that failed is named with its reason in the error box, and one
  /// the admin skipped is only mentioned under the bar: a skip is a choice.
  Future<void> _updateAll(List<DockOutdated> outdated) async {
    clearActionError();
    setState(() {
      _updatingAll = true;
      _updateReport = null;
    });
    final report = await updateAllDockModules(
      context: context,
      ref: ref,
      outdated: outdated,
    );
    if (report == null || !mounted) return;
    setState(() {
      _updatingAll = false;
      _updateReport = report;
    });
    if (report.failures.isNotEmpty) setActionError(report.failures.join(' '));
  }

  DockListFilter _filterFor(DockCatalog catalog) =>
      _filter ??
      (catalog.installed.isEmpty
          ? DockListFilter.browse
          : DockListFilter.installed);

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(dockCatalogProvider);
    final needle = _query.text.trim().toLowerCase();
    return AppAsyncView<DockCatalog>(
      value: AppAsyncState(data: catalog.valueOrNull, error: catalog.error),
      center: false,
      errorMessage: 'Could not reach the module marketplace.',
      onRetry: () => ref.invalidate(dockCatalogProvider),
      data: (context, catalog) {
        final filter = _filterFor(catalog);
        final outdated = _outdated(catalog);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DockPaneHeader(
              filter: filter,
              onFilter: (f) => setState(() => _filter = f),
              onInstallFile: () => unawaited(
                installDockModuleFromFile(context, guard, setActionError),
              ),
              onAddSource: () => unawaited(showAddDockSourceSheet(context)),
              onManageSources: () =>
                  unawaited(showManageDockSourcesSheet(context)),
            ),
            const SizedBox(height: AppSpacing.s12),
            if (actionError case final message?) ...[
              AppErrorState(message: message, onDismiss: clearActionError),
              const SizedBox(height: AppSpacing.s12),
            ],
            if (outdated.isNotEmpty)
              _UpdateAllBar(
                count: outdated.length,
                busy: _updatingAll,
                summary: _updateReport?.summary(outdated),
                onUpdateAll: () => unawaited(_updateAll(outdated)),
              ),
            RingFlush(
              child: AppInput(
                controller: _query,
                placeholder: 'Search modules',
                semanticLabel: 'Search modules',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            if (filter == DockListFilter.installed)
              ..._installedView(catalog, needle)
            else
              ..._browseView(catalog, needle),
          ],
        );
      },
    );
  }

  List<Widget> _installedView(DockCatalog catalog, String needle) {
    final rows = [
      for (final m in catalog.installed)
        if (needle.isEmpty || _matches(_entryFor(catalog, m), needle))
          DockModuleRow(
            entry: _entryFor(catalog, m),
            installed: m,
            source: _sourceIdOf(catalog, m),
            showInstalledState: false,
          ),
    ];
    return [
      SettingsSectionCard(
        topGap: 0,
        children: [
          if (rows.isEmpty)
            SettingsEmptyState(
              icon: AppIcons.dock,
              title: catalog.installed.isEmpty
                  ? 'No modules installed yet.'
                  : 'No module matches "${_query.text.trim()}".',
              detail: catalog.installed.isEmpty ? 'Browse to add one.' : null,
            )
          else
            ...rows,
        ],
      ),
    ];
  }

  /// The marketplace listing for [m], or one built from what is installed
  /// when its source no longer lists it (a file, a removed source).
  static api.DockIndexEntry _entryFor(
    DockCatalog catalog,
    api.InstalledDockModule m,
  ) {
    final listed = [
      ...catalog.entries,
      for (final s in catalog.sections) ...s.entries,
    ];
    return listed.where((e) => e.id == m.id).firstOrNull ??
        api.DockIndexEntry(
          id: m.id,
          name: m.name,
          version: m.version,
          summary: '',
        );
  }

  /// The route's `source` for [m]: null for the official source.
  static String? _sourceIdOf(DockCatalog catalog, api.InstalledDockModule m) {
    final repo = m.sourceRepo;
    if (repo == null) return null;
    if (repo == api.kFileDockRepo) return api.kFileDockSource;
    return catalog.sections
        .where((s) => s.source.repo == repo)
        .firstOrNull
        ?.source
        .id;
  }

  List<Widget> _browseView(DockCatalog catalog, String needle) {
    final shown = [
      for (final entry in catalog.entries)
        if (needle.isEmpty || _matches(entry, needle)) entry,
    ];
    return [
      _officialModules(catalog, shown),
      for (final section in catalog.sections)
        DockCommunitySection(
          section: section,
          catalog: catalog,
          needle: needle,
        ),
      if (catalog.sourcesFailed) ...[
        const SizedBox(height: AppSpacing.s12),
        const AppErrorState(message: 'Could not load the community sources.'),
      ],
    ];
  }

  Widget _officialModules(DockCatalog catalog, List<api.DockIndexEntry> shown) {
    if (shown.isEmpty) {
      return SettingsSectionCard(
        topGap: 0,
        children: [
          SettingsEmptyState(
            icon: AppIcons.dock,
            title: catalog.entries.isEmpty
                ? 'No modules are published in the marketplace yet.'
                : 'No module matches "${_query.text.trim()}".',
          ),
        ],
      );
    }
    return SettingsSectionCard(
      title: catalog.sections.isEmpty ? null : 'Official modules',
      topGap: catalog.sections.isEmpty ? 0 : kSettingsSectionTopGap,
      children: [
        for (final entry in shown)
          DockModuleRow(
            entry: entry,
            installed: catalog.installedFor(entry.id),
          ),
      ],
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
    required this.summary,
    required this.onUpdateAll,
  });

  final int count;
  final bool busy;

  /// What the last press left undone, when it left anything.
  final String? summary;
  final VoidCallback onUpdateAll;

  @override
  Widget build(BuildContext context) {
    final subject = count == 1 ? '1 module has' : '$count modules have';
    return SettingsSectionCard(
      children: [
        SettingsDetailRow(
          icon: AppIcons.dock,
          title: '$subject an update',
          detail: summary,
          trailing: AppButton(
            label: busy ? 'Updating...' : 'Update all',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.sm,
            disabled: busy,
            onPressed: onUpdateAll,
            semanticLabel: 'Update all modules',
          ),
        ),
      ],
    );
  }
}
