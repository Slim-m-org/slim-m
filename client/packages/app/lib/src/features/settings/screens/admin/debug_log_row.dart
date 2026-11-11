// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One received debug log: who sent it and from what, with copy, download and delete.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../../providers/providers.dart';
import '../../../../providers/toasts.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../../widgets/run_guarded.dart';
import '../../providers/debug_logs_controller.dart';
import '../../providers/theme_file_io.dart';
import '../../widgets/settings_entity_row.dart';

String _size(int bytes) =>
    bytes < 1024 ? '$bytes B' : '${(bytes / 1024).ceil()} KB';

String _fileName(api.DebugLogEntry entry) =>
    'debug-log-${entry.username}-${entry.id}.txt';

class DebugLogRow extends ConsumerStatefulWidget {
  const DebugLogRow({super.key, required this.entry});

  final api.DebugLogEntry entry;

  @override
  ConsumerState<DebugLogRow> createState() => _DebugLogRowState();
}

class _DebugLogRowState extends ConsumerState<DebugLogRow> {
  bool _busy = false;
  String? _error;

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await runGuarded(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  Future<String> _text() async =>
      (await ref.read(apiProvider).getDebugLog(widget.entry.id)).log;

  Future<void> _copy() => _run('copy the debug log', () async {
    await Clipboard.setData(ClipboardData(text: await _text()));
    if (!mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show('Debug log copied', severity: AppToastSeverity.success);
  });

  Future<void> _download() => _run('download the debug log', () async {
    final text = await _text();
    await ref.read(themeFileSaverProvider)(
      _fileName(widget.entry),
      utf8.encode(text),
    );
  });

  Future<void> _delete() async {
    final ok = await confirmDangerousAction(
      context,
      title: 'Delete debug log?',
      message: 'This removes it for every admin. This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!ok || !mounted) return;
    final controller = ref.read(debugLogsControllerProvider.notifier);
    await _run(
      'delete the debug log',
      () => controller.delete(widget.entry.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final entry = widget.entry;
    final caption = AppText.caption.copyWith(color: tokens.textSecondary);
    final sender = entry.displayName.isEmpty
        ? entry.username
        : entry.displayName;
    return SettingsEntityRow(
      headline: sender,
      details: [
        Text(
          '${formatRelativeAgeMs(entry.createdAt, weeks: true)} - ${_size(entry.sizeBytes)}',
          style: caption,
        ),
        Text('${entry.platform} - ${entry.appVersion}', style: caption),
        if (entry.note.isNotEmpty)
          Text(
            entry.note,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
      ],
      actions: [
        AppIconButton(
          icon: AppIcons.copy,
          semanticLabel: 'Copy log from $sender',
          tooltip: 'Copy',
          onPressed: _busy ? null : () => unawaited(_copy()),
        ),
        AppIconButton(
          icon: AppIcons.download,
          semanticLabel: 'Download log from $sender',
          tooltip: 'Download',
          onPressed: _busy ? null : () => unawaited(_download()),
        ),
        AppIconButton(
          icon: AppIcons.delete,
          semanticLabel: 'Delete log from $sender',
          tooltip: 'Delete',
          onPressed: _busy ? null : () => unawaited(_delete()),
        ),
      ],
      error: _error,
      onErrorDismiss: () => setState(() => _error = null),
    );
  }
}
