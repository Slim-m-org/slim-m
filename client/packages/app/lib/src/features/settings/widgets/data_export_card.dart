// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A data export card: the start action plus the newest job's status, progress and download.
/// Used for a member's own data and for the whole Space (ADMINISTRATOR); starting asks for the password (decision 0084).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../auth/widgets/reauth_sheet.dart';
import '../providers/data_exports.dart';
import 'data_export_copy.dart';
import 'data_export_job_row.dart';
import 'settings_detail_row.dart';
import 'settings_section_header.dart';

class DataExportCard extends ConsumerWidget {
  const DataExportCard({super.key, required this.copy});

  final DataExportCopy copy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(dataExportsProvider);
    final job = latestExport(jobs.valueOrNull ?? const [], copy.kind);
    final busy = job?.status.isActive ?? false;
    return SettingsSectionCard(
      title: copy.title,
      description: copy.description,
      children: [
        SettingsDetailRow(
          icon: AppIcons.download,
          title: copy.rowTitle,
          detail: copy.rowDetail,
          stackTrailingWhenNarrow: true,
          trailing: AppButton(
            label: copy.startLabel,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: busy ? null : () => _start(context, ref),
          ),
        ),
        if (jobs.hasError)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s12,
            ),
            child: AppErrorState(
              message: 'Could not load your exports.',
              onRetry: () => ref.invalidate(dataExportsProvider),
            ),
          ),
        if (job != null) DataExportJobRow(job: job, copy: copy),
      ],
    );
  }

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    await showReauthSheet(
      context,
      title: copy.rowTitle,
      description: copy.sheetDescription,
      submitLabel: copy.startLabel.replaceAll('...', ''),
      onSubmit: (password, _) async {
        try {
          final client = ref.read(apiProvider);
          copy.kind == api.ExportKind.space
              ? await client.startSpaceExport(password: password)
              : await client.startMemberExport(password: password);
          ref.invalidate(dataExportsProvider);
          return null;
        } on api.ApiException catch (e, stack) {
          api.reportFailure(api.LogTag.ui, copy.failureWhat, e, stack);
          return e is api.RateLimitedException
              ? 'An export was just made, or there were too many password tries. Wait a few minutes.'
              : reauthFailure(e);
        }
      },
    );
  }
}
