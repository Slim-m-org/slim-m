// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Transcript": what was said in a call (decision 0113), under "What
/// happened". The first few lines show, "Show all" opens the rest a page at a
/// time, and a search hit scrolls to its line.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../../permissions.dart';
import '../../../../widgets/confirm_dialog.dart';
import '../../../channels/providers/channel_permissions.dart';
import '../../../members/providers/user_profiles.dart';
import '../../../members/widgets/user_avatar.dart';
import '../../../settings/providers/display_preferences.dart';
import '../../providers/call_transcript.dart';
import '../../providers/voice_call_history.dart';
import 'call_fold_link.dart';

/// Lines shown before "Show all".
const transcriptCollapsedLines = 8;

const transcriptDeleteKey = Key('transcript-delete');
const transcriptShowAllKey = Key('transcript-show-all');
const transcriptShowMoreKey = Key('transcript-show-more');

Key transcriptLineKey(int seq) => ValueKey('transcript-line-$seq');

class CallTranscriptSection extends ConsumerStatefulWidget {
  const CallTranscriptSection({
    super.key,
    required this.channelId,
    required this.transcriptId,
  });

  final String channelId;
  final String transcriptId;

  @override
  ConsumerState<CallTranscriptSection> createState() =>
      _CallTranscriptSectionState();
}

class _CallTranscriptSectionState extends ConsumerState<CallTranscriptSection> {
  bool _expanded = false;
  int? _highlighted;
  final _lineKeys = <int, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _followFocus());
  }

  GlobalKey _keyFor(int seq) => _lineKeys.putIfAbsent(seq, GlobalKey.new);

  Future<void> _followFocus() async {
    if (!mounted) return;
    final focus = ref.read(transcriptFocusProvider);
    if (focus == null || focus.transcriptId != widget.transcriptId) return;
    setState(() => _expanded = true);
    final controller = ref.read(
      callTranscriptProvider(widget.transcriptId).notifier,
    );
    await controller.loadThrough(focus.seq);
    if (!mounted) return;
    ref.read(transcriptFocusProvider.notifier).state = null;
    setState(() => _highlighted = focus.seq);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _lineKeys[focus.seq]?.currentContext;
      if (target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.3,
          duration: const Duration(milliseconds: 200),
        ),
      );
    });
  }

  Future<void> _delete() async {
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Delete this transcript?',
      message: 'It is removed for everyone. This cannot be undone.',
      confirmLabel: 'Delete transcript',
    );
    if (!confirmed || !mounted) return;
    final controller = ref.read(
      callTranscriptProvider(widget.transcriptId).notifier,
    );
    if (await controller.delete()) {
      ref.invalidate(voiceCallHistoryProvider(widget.channelId));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(transcriptFocusProvider, (_, focus) {
      if (focus?.transcriptId == widget.transcriptId) {
        unawaited(_followFocus());
      }
    });
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final model = ref.watch(callTranscriptProvider(widget.transcriptId));
    if (model.deleted) return const SizedBox.shrink();
    final canDelete = ref
        .watch(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageMessages);
    final folded = !_expanded && model.lines.length > transcriptCollapsedLines;
    final shown = folded
        ? model.lines.take(transcriptCollapsedLines).toList()
        : model.lines;
    final showAll = folded || (!_expanded && model.hasMore);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.s12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Transcript',
                  style: AppText.ui.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              if (canDelete && model.loaded)
                AppButton(
                  key: transcriptDeleteKey,
                  label: 'Delete',
                  size: AppButtonSize.sm,
                  variant: AppButtonVariant.ghost,
                  onPressed: model.busy ? null : _delete,
                ),
            ],
          ),
        ),
        for (final line in shown)
          _LineRow(
            key: _keyFor(line.seq),
            line: line,
            highlighted: line.seq == _highlighted,
          ),
        if (model.loaded && model.error == null && model.lines.isEmpty)
          Text(
            model.ongoing ? 'Nothing said yet.' : 'Nothing was said.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        if (model.error case final message?)
          AppErrorState(
            message: message,
            onRetry: () => ref
                .read(callTranscriptProvider(widget.transcriptId).notifier)
                .loadMore(),
          ),
        if (showAll)
          Align(
            alignment: Alignment.centerLeft,
            child: CallFoldLink(
              key: transcriptShowAllKey,
              label: 'Show all',
              onPressed: () => setState(() => _expanded = true),
            ),
          )
        else if (_expanded && model.hasMore)
          Align(
            alignment: Alignment.centerLeft,
            child: CallFoldLink(
              key: transcriptShowMoreKey,
              label: 'Show more',
              onPressed: () => ref
                  .read(callTranscriptProvider(widget.transcriptId).notifier)
                  .loadMore(),
            ),
          ),
      ],
    );
  }
}

class _LineRow extends ConsumerWidget {
  const _LineRow({super.key, required this.line, required this.highlighted});

  final api.TranscriptLine line;
  final bool highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name =
        ref
            .watch(userProfileProvider(line.speakerId))
            .valueOrNull
            ?.displayName ??
        'Someone';
    final time = formatClock(
      DateTime.fromMillisecondsSinceEpoch(line.at),
      use24Hour: watchUse24Hour(ref, context),
    );
    return Container(
      key: transcriptLineKey(line.seq),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      decoration: BoxDecoration(
        color: highlighted ? tokens.accentSoft : null,
        borderRadius: BorderRadius.circular(AppRadii.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(
            name: name,
            userId: line.speakerId,
            size: AppAvatarSize.s28,
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.ui.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: AppWeights.medium,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    Text(
                      time,
                      style: AppText.code.copyWith(color: tokens.textSecondary),
                    ),
                  ],
                ),
                Text(
                  line.text,
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
