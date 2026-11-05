// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The nightly backup's last verified time in Storage, or why there is none.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../../widgets/attachment_format.dart' show formatByteSize;
import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_section_header.dart';

class BackupStatusCard extends StatelessWidget {
  const BackupStatusCard({super.key, required this.backup, this.now});

  final api.SpaceBackupStatus backup;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final line = backupLine(backup, now: now);
    return SettingsSectionCard(
      title: 'Backups',
      children: [
        SettingsDetailRow(
          key: const Key('backup-status-row'),
          icon: AppIcons.storage,
          title: 'Last verified backup',
          detail: line.detail,
          badge: line.warn
              ? const AppBadge(
                  key: Key('backup-status-warning'),
                  variant: AppBadgeVariant.warn,
                  label: 'Needs attention',
                )
              : null,
        ),
      ],
    );
  }
}

/// What the row says, and whether it deserves the warning badge.
({String detail, bool warn}) backupLine(
  api.SpaceBackupStatus backup, {
  DateTime? now,
}) {
  final verified = backup.verifiedAt == null
      ? null
      : '${formatRelativeAgeMs(backup.verifiedAt!, now: now)}'
            '${backup.verifiedBytes == null ? '' : ', ${formatByteSize(backup.verifiedBytes!)}'}';
  switch (backup.state) {
    case api.BackupState.notConfigured:
      return (detail: 'Not set up', warn: false);
    case api.BackupState.never:
      return (detail: 'Never', warn: false);
    case api.BackupState.unreadable:
      return (detail: 'The backup status cannot be read.', warn: true);
    case api.BackupState.failed:
      final error = backup.error?.isNotEmpty == true
          ? backup.error!
          : 'The last run failed.';
      return (
        detail: verified == null
            ? _sentence(error)
            : '${_sentence(error)} Last verified $verified.',
        warn: true,
      );
    case api.BackupState.verified:
      final text = verified ?? 'Never';
      return (
        detail: backup.stale ? '$text. Older than 48 hours.' : text,
        warn: backup.stale,
      );
  }
}

/// A runner's raw error, closed as a sentence so the next one does not run into it.
String _sentence(String text) =>
    RegExp(r'[.!?]$').hasMatch(text) ? text : '$text.';
