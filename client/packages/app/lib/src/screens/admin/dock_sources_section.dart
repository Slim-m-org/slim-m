// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock's community sources (decision 0046): one section per source
/// under the official list, each labelled with where its modules come from,
/// plus the sheet that adds one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../api_failure.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_module_row.dart';

/// One community source: its label, a remove control, and its modules or the
/// reason they could not be listed.
class DockCommunitySection extends StatelessWidget {
  const DockCommunitySection({
    super.key,
    required this.section,
    required this.catalog,
    required this.needle,
    required this.onRemove,
  });

  final DockSourceSection section;
  final DockCatalog catalog;

  /// The lowercase search text; empty shows every module.
  final String needle;
  final VoidCallback onRemove;

  bool _matches(api.DockIndexEntry e) =>
      needle.isEmpty ||
      e.name.toLowerCase().contains(needle) ||
      e.id.toLowerCase().contains(needle) ||
      e.summary.toLowerCase().contains(needle);

  /// Installed here only if it came from this very source; another source's
  /// install of the same id is not this row's state.
  api.InstalledDockModule? _installedHere(api.DockIndexEntry e) {
    final installed = catalog.installedFor(e.id);
    return installed?.sourceRepo == section.source.repo ? installed : null;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final repo = section.source.repo;
    final shown = section.entries.where(_matches).toList(growable: false);
    return SettingsSectionCard(
      title: 'Community source: $repo',
      description:
          'Not the official registry, so review what each module can do.',
      children: [
        if (section.failed)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s8),
            child: AppErrorState(message: 'Could not load modules from $repo.'),
          )
        else if (section.entries.isEmpty)
          _note('This source lists no modules.', tokens)
        else if (shown.isEmpty)
          _note('No module in this source matches the search.', tokens)
        else
          for (final entry in shown)
            DockModuleRow(
              entry: entry,
              installed: _installedHere(entry),
              source: section.source.id,
            ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: AppButton(
            label: 'Remove this source',
            icon: AppIcons.delete,
            variant: AppButtonVariant.danger,
            size: AppButtonSize.sm,
            semanticLabel: 'Remove source $repo',
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }

  Widget _note(String text, AppTokens tokens) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s8),
    child: Text(
      text,
      style: AppText.body.copyWith(color: tokens.textSecondary),
    ),
  );
}

Future<void> showAddDockSourceSheet(BuildContext context) {
  return showAppSheet<void>(
    context,
    builder: (context) => const _AddSourceSheet(),
  );
}

class _AddSourceSheet extends ConsumerStatefulWidget {
  const _AddSourceSheet();

  @override
  ConsumerState<_AddSourceSheet> createState() => _AddSourceSheetState();
}

class _AddSourceSheetState extends ConsumerState<_AddSourceSheet> {
  final _repo = TextEditingController();
  bool _submitting = false;
  String? _error;

  bool get _canSubmit => !_submitting && _repo.text.trim().isNotEmpty;

  @override
  void dispose() {
    _repo.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).addDockSource(_repo.text.trim());
      ref.invalidate(dockCatalogProvider);
      if (mounted) Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = describeApiFailure('add the source', e);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add a community source',
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'A GitHub repo (owner/repo) with an index.json; its modules are '
            'unreviewed.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          AppInput(
            controller: _repo,
            placeholder: 'owner/repo',
            semanticLabel: 'Source repository',
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _canSubmit ? _submit() : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: _error!),
          ],
          const SizedBox(height: AppSpacing.s16),
          AppButton(
            label: _submitting ? 'Adding...' : 'Add source',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: !_canSubmit,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
