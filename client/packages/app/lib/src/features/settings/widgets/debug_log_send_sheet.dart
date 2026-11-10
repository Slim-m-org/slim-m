// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet that sends the debug log to the admins: says what goes, takes an
/// optional note, and shows sent or the reason it was not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/labeled_field.dart';
import '../providers/debug_log_send.dart';

/// Opens the send prompt.
Future<void> showDebugLogSendSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const DebugLogSendSheet());

class DebugLogSendSheet extends ConsumerStatefulWidget {
  const DebugLogSendSheet({super.key});

  @override
  ConsumerState<DebugLogSendSheet> createState() => _DebugLogSendSheetState();
}

class _DebugLogSendSheetState extends ConsumerState<DebugLogSendSheet> {
  final _note = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send(DebugLogContents contents) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await ref
        .read(debugLogSenderProvider)
        .send(contents, _note.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
      _sent = failure == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final contents = ref.watch(debugLogContentsProvider).valueOrNull;
    return Padding(
      key: const ValueKey('debug-log-send-sheet'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Send debug log',
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Close',
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s8),
          if (_sent) ..._sentBody(tokens) else ..._form(tokens, contents),
        ],
      ),
    );
  }

  List<Widget> _sentBody(AppTokens tokens) => [
    Text(
      'Sent. The admins can now read it.',
      style: AppText.body.copyWith(color: tokens.textPrimary),
    ),
    const SizedBox(height: AppSpacing.s12),
    AppButton(
      label: 'Done',
      variant: AppButtonVariant.primary,
      full: true,
      onPressed: () => Navigator.of(context).pop(),
    ),
  ];

  List<Widget> _form(AppTokens tokens, DebugLogContents? contents) => [
    Text(
      'Sends the debug log, your app version and your platform to the '
      'admins of this Space. Tokens and passwords are removed first.',
      style: AppText.body.copyWith(color: tokens.textSecondary),
    ),
    if (contents != null) ...[
      const SizedBox(height: AppSpacing.s8),
      Text(
        '${contents.entries} log entries, version ${contents.appVersion}, '
        '${contents.platform}',
        key: const ValueKey('debug-log-send-contents'),
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    ],
    const SizedBox(height: AppSpacing.s12),
    LabeledField(
      label: 'Note',
      helper: 'Optional. What went wrong?',
      child: AppInput(
        key: const ValueKey('debug-log-note-field'),
        controller: _note,
        maxLength: debugLogNoteMaxChars,
        maxLines: 3,
        semanticLabel: 'Note for the admins',
      ),
    ),
    if (_error != null) ...[
      const SizedBox(height: AppSpacing.s8),
      AppErrorState(message: _error!),
    ],
    const SizedBox(height: AppSpacing.s12),
    AppButton(
      label: _busy ? 'Sending...' : 'Send',
      variant: AppButtonVariant.primary,
      full: true,
      disabled: _busy || contents == null,
      onPressed: contents == null ? null : () => _send(contents),
    ),
  ];
}
