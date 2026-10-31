// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One export job's status row: waiting, building with a progress bar, ready
/// with a download, saving, failed, or expired.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import '../../../widgets/attachment_format.dart' show formatByteSize;
import '../providers/data_export_download.dart';
import '../providers/data_exports.dart';
import 'data_export_copy.dart';
import 'settings_detail_row.dart';
import 'settings_result_inset.dart';

class DataExportJobRow extends ConsumerStatefulWidget {
  const DataExportJobRow({super.key, required this.job, required this.copy});

  final api.DataExport job;
  final DataExportCopy copy;

  @override
  ConsumerState<DataExportJobRow> createState() => _DataExportJobRowState();
}

class _DataExportJobRowState extends ConsumerState<DataExportJobRow>
    with GuardedActionState<DataExportJobRow> {
  Future<void> _remove() => guard(
    whatFailed: 'delete the export',
    action: () async {
      await ref.read(apiProvider).deleteExport(widget.job.id);
      ref.invalidate(dataExportsProvider);
    },
  );

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final save = ref.watch(exportSavesProvider.select((s) => s[job.id]));
    final row = switch (job.status) {
      api.ExportStatus.queued || api.ExportStatus.running => _building(job),
      api.ExportStatus.ready => _ready(job, save),
      api.ExportStatus.failed => _failed(job),
      api.ExportStatus.expired => _expired(),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        if (actionError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s12,
            ),
            child: AppErrorState(
              message: actionError!,
              onDismiss: clearActionError,
            ),
          ),
      ],
    );
  }

  Widget _building(api.DataExport job) {
    final percent = job.fraction == null ? null : (job.fraction! * 100).floor();
    final label = job.status == api.ExportStatus.queued
        ? 'Waiting to start'
        : 'Preparing the archive';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsDetailRow(
          icon: AppIcons.download,
          title: label,
          detail: percent == null ? 'Counting what to include' : '$percent%',
          stackTrailingWhenNarrow: true,
          trailing: AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            onPressed: _remove,
          ),
        ),
        _Bar(value: job.fraction, label: label),
      ],
    );
  }

  Widget _ready(api.DataExport job, ExportSave? save) {
    final saves = ref.read(exportSavesProvider.notifier);
    if (save?.phase == ExportSavePhase.saving) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsDetailRow(
            icon: AppIcons.download,
            title: 'Downloading',
            detail: save!.fraction == null
                ? formatByteSize(save.received)
                : '${(save.fraction! * 100).floor()}%',
            stackTrailingWhenNarrow: true,
            trailing: AppButton(
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: () => saves.cancel(job.id),
            ),
          ),
          _Bar(value: save.fraction, label: 'Downloading'),
        ],
      );
    }
    final size = job.sizeBytes == null
        ? ''
        : '${formatByteSize(job.sizeBytes!)}, ';
    final left = job.expiresAt == null
        ? null
        : Duration(
            milliseconds:
                job.expiresAt! - DateTime.now().millisecondsSinceEpoch,
          );
    return SettingsDetailRow(
      icon: AppIcons.download,
      title: save?.phase == ExportSavePhase.done
          ? 'Saved'
          : 'Ready to download',
      detail:
          '${size}deleted ${left == null ? 'soon' : 'in ${_remaining(left)}'}',
      stackTrailingWhenNarrow: true,
      error: save?.phase == ExportSavePhase.failed ? save?.message : null,
      onErrorDismiss: () => saves.dismiss(job.id),
      trailing: Wrap(
        spacing: AppSpacing.s8,
        children: [
          AppButton(
            label: 'Download',
            size: AppButtonSize.sm,
            onPressed: () => saves.start(job),
          ),
          AppButton(
            label: 'Delete',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            onPressed: _remove,
          ),
        ],
      ),
    );
  }

  Widget _failed(api.DataExport job) => SettingsDetailRow(
    icon: AppIcons.download,
    title: 'The export failed',
    error: job.error ?? 'The export could not be finished.',
    onErrorDismiss: _remove,
  );

  Widget _expired() => SettingsDetailRow(
    icon: AppIcons.download,
    title: 'The last export expired',
    detail: 'Archives are kept for 24 hours.',
    stackTrailingWhenNarrow: true,
    trailing: AppButton(
      label: 'Remove',
      variant: AppButtonVariant.ghost,
      size: AppButtonSize.sm,
      onPressed: _remove,
    ),
  );
}

String _remaining(Duration left) {
  if (left.inHours >= 1) return '${left.inHours} h';
  if (left.inMinutes >= 1) return '${left.inMinutes} min';
  return 'under a minute';
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.label});

  final double? value;
  final String label;

  @override
  Widget build(BuildContext context) => SettingsResultInset(
    child: LinearProgressIndicator(
      value: value,
      minHeight: 3,
      semanticsLabel: label,
    ),
  );
}
