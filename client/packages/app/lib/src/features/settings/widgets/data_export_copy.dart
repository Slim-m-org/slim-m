// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The words around a data export, kept beside each other so what an archive
/// holds is stated once and the two cards cannot drift apart.
library;

import 'package:slimm_api/api.dart' as api;

class DataExportCopy {
  const DataExportCopy({
    required this.kind,
    required this.title,
    required this.description,
    required this.rowTitle,
    required this.rowDetail,
    required this.startLabel,
    required this.sheetDescription,
    required this.failureWhat,
  });

  final api.ExportKind kind;
  final String title;
  final String description;
  final String rowTitle;
  final String rowDetail;
  final String startLabel;

  /// Exactly what the archive holds and leaves out, shown while the password is asked for.
  final String sheetDescription;
  final String failureWhat;

  static const member = DataExportCopy(
    kind: api.ExportKind.member,
    title: 'Your data',
    description: 'A copy of what you wrote and uploaded.',
    rowTitle: 'Download my data',
    rowDetail: 'Messages, reactions, saved items, notes and uploads.',
    startLabel: 'Prepare download...',
    sheetDescription:
        'The archive holds your profile and settings, the messages you wrote '
        '(your side of direct messages too), reactions, saved message ids, '
        'notes, blocks, poll votes, call times and files you uploaded. '
        'Never anyone else\'s messages. It is deleted after 24 hours.',
    failureWhat: 'prepare your data',
  );

  static const space = DataExportCopy(
    kind: api.ExportKind.space,
    title: 'Export this Space',
    description: 'A full copy of channels, messages and files.',
    rowTitle: 'Download a copy',
    rowDetail: 'Never includes direct messages or sign-in data.',
    startLabel: 'Prepare export...',
    sheetDescription:
        'The archive holds channels, threads, roles, members, messages with '
        'their files, pins and custom emoji. It never holds direct messages, '
        'deleted content, passwords, sessions or tokens. It is deleted after '
        '24 hours, and this is written to the audit log.',
    failureWhat: 'prepare the export',
  );
}
