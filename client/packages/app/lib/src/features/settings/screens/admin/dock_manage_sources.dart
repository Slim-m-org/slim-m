// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet behind "Manage sources": every community source, each removable.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/settings_detail_row.dart';
import '../../widgets/settings_section_header.dart';
import 'dock_sources_section.dart';

Future<void> showManageDockSourcesSheet(BuildContext context) =>
    showAppSheet<void>(
      context,
      scrolls: true,
      builder: (context) => const _ManageSourcesSheet(),
    );

class _ManageSourcesSheet extends ConsumerStatefulWidget {
  const _ManageSourcesSheet();

  @override
  ConsumerState<_ManageSourcesSheet> createState() =>
      _ManageSourcesSheetState();
}

class _ManageSourcesSheetState extends ConsumerState<_ManageSourcesSheet>
    with GuardedActionState<_ManageSourcesSheet> {
  Future<void> _remove(api.DockSource source) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Remove ${source.repo}?',
      message:
          'Modules installed from it stay installed, but cannot be updated '
          'until you add it again.',
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
    final sources = [
      for (final s
          in ref.watch(dockCatalogProvider).valueOrNull?.sections ??
              const <DockSourceSection>[])
        s.source,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Community sources',
            style: AppText.heading.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          if (actionError case final message?) ...[
            AppErrorState(message: message, onDismiss: clearActionError),
            const SizedBox(height: AppSpacing.s12),
          ],
          if (sources.isEmpty)
            Text(
              'No community sources yet.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            )
          else
            SettingsSectionCard(
              children: [
                for (final source in sources)
                  SettingsDetailRow(
                    icon: AppIcons.dock,
                    title: source.local ? 'Local dev directory' : source.repo,
                    trailing: source.local
                        ? null
                        : AppButton(
                            label: 'Remove',
                            icon: AppIcons.delete,
                            variant: AppButtonVariant.danger,
                            size: AppButtonSize.sm,
                            semanticLabel: 'Remove source ${source.repo}',
                            onPressed: () => unawaited(_remove(source)),
                          ),
                  ),
              ],
            ),
          const SizedBox(height: AppSpacing.s16),
          AppButton(
            label: 'Add a community source',
            icon: AppIcons.add,
            onPressed: () => unawaited(showAddDockSourceSheet(context)),
          ),
        ],
      ),
    );
  }
}
