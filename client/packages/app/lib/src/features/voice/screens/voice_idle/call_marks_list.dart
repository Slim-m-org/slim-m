// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Marks and notes" at the top of a call's Transcript section: each mark's
/// maker, time and note or line. A tap jumps to the line; the author or a
/// message moderator may remove one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../../permissions.dart';
import '../../../../providers/session_provider.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../channels/providers/channel_permissions.dart';
import '../../../members/providers/user_profiles.dart';
import '../../../settings/providers/display_preferences.dart';
import '../../providers/call_transcript.dart';
import '../../providers/call_transcript_marks.dart';

Key callMarkRowKey(String markId) => ValueKey('call-mark-row-$markId');
Key callMarkDeleteKey(String markId) => ValueKey('call-mark-delete-$markId');

class CallMarksList extends ConsumerStatefulWidget {
  const CallMarksList({
    super.key,
    required this.channelId,
    required this.transcriptId,
  });

  final String channelId;
  final String transcriptId;

  @override
  ConsumerState<CallMarksList> createState() => _CallMarksListState();
}

class _CallMarksListState extends ConsumerState<CallMarksList> {
  String? _error;

  Future<void> _delete(api.TranscriptMark mark) async {
    final confirmed = await confirmDangerousAction(
      context,
      title: mark.text == null ? 'Remove this mark?' : 'Remove this note?',
      message: 'It is removed for everyone who reads this call.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    final failed = await ref
        .read(transcriptMarksProvider(widget.transcriptId).notifier)
        .delete(mark.id);
    if (mounted) setState(() => _error = failed);
  }

  void _jump(api.TranscriptMark mark) {
    final seq = mark.lineSeq;
    if (seq == null) return;
    ref.read(transcriptFocusProvider.notifier).state = (
      channelId: widget.channelId,
      transcriptId: widget.transcriptId,
      seq: seq,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final model = ref.watch(transcriptMarksProvider(widget.transcriptId));
    final error = _error ?? model.error;
    if (model.marks.isEmpty && error == null) return const SizedBox.shrink();
    final me = ref.watch(sessionProvider.select((s) => s.tokens?.userId));
    final moderator = ref
        .watch(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageMessages);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Marks and notes',
            style: AppText.caption.copyWith(
              color: tokens.textSecondary,
              fontWeight: AppWeights.medium,
            ),
          ),
          for (final mark in model.marks)
            _MarkRow(
              mark: mark,
              transcriptId: widget.transcriptId,
              onTap: mark.lineSeq == null ? null : () => _jump(mark),
              onDelete: mark.authorId == me || moderator
                  ? () => unawaited(_delete(mark))
                  : null,
            ),
          if (error != null) AppErrorState(message: error),
        ],
      ),
    );
  }
}

/// The text of line [seq], found by search since lines are kept in seq order.
String? _lineText(List<api.TranscriptLine> lines, int? seq) {
  if (seq == null) return null;
  var low = 0;
  var high = lines.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final at = lines[mid].seq;
    if (at == seq) return lines[mid].text;
    if (at < seq) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return null;
}

class _MarkRow extends ConsumerWidget {
  const _MarkRow({
    required this.mark,
    required this.transcriptId,
    required this.onTap,
    required this.onDelete,
  });

  final api.TranscriptMark mark;

  final String transcriptId;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    final name =
        ref
            .watch(userProfileProvider(mark.authorId))
            .valueOrNull
            ?.displayName ??
        'Someone';
    final time = formatClock(
      DateTime.fromMillisecondsSinceEpoch(mark.at),
      use24Hour: watchUse24Hour(ref, context),
    );
    final line = ref.watch(
      callTranscriptProvider(
        transcriptId,
      ).select((m) => _lineText(m.lines, mark.lineSeq)),
    );
    final detail = mark.text ?? line;
    final note = mark.text != null;
    return Row(
      key: callMarkRowKey(mark.id),
      children: [
        Expanded(
          child: Semantics(
            button: onTap != null,
            label:
                '${note ? 'Note' : 'Mark'} by $name at $time'
                '${detail == null ? '' : ': $detail'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadii.control),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: touch ? AppSizes.rowTouch : AppSizes.rowPointer,
                ),
                child: Row(
                  children: [
                    Icon(
                      note ? AppIcons.callNote : AppIcons.callMark,
                      size: AppSizes.icon16,
                      color: tokens.textSecondary,
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: name,
                              style: const TextStyle(
                                fontWeight: AppWeights.medium,
                              ),
                            ),
                            TextSpan(
                              text: '  $time',
                              style: AppText.code.copyWith(
                                color: tokens.textSecondary,
                              ),
                            ),
                            if (detail != null) TextSpan(text: '  $detail'),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui.copyWith(color: tokens.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (onDelete != null)
          AppIconButton(
            key: callMarkDeleteKey(mark.id),
            icon: AppIcons.delete,
            semanticLabel: note ? 'Remove note' : 'Remove mark',
            tooltip: note ? 'Remove note' : 'Remove mark',
            size: touch ? AppIconButtonSize.touch : AppIconButtonSize.sm,
            iconSize: AppSizes.icon16,
            onPressed: onDelete,
          ),
      ],
    );
  }
}
