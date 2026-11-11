// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel while you are not in its call (design 13, decision
/// 0066): a join bar, then the latest call's record - who was in when, what
/// happened, so far if it is still going - and the calls before it. Each part stands alone, so a channel
/// with no history still gets its join bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../channels/providers/channel_by_id_provider.dart';
import '../../../settings/providers/display_preferences.dart';
import '../../providers/voice_call_history.dart';
import '../../../../routing/breakpoints.dart';
import '../../providers/call_recap.dart';
import '../../widgets/call_recap_card.dart';
import 'call_history_rows.dart';
import 'call_moments_view.dart';
import 'call_timeline_model.dart';
import 'call_timeline_view.dart';
import 'voice_join_bar.dart';

class VoiceChannelIdle extends ConsumerWidget {
  const VoiceChannelIdle({
    super.key,
    required this.channelId,
    required this.onJoin,
    required this.onOpenCanvas,
    this.errorMessage,
    this.canRetry = true,
    this.recap,
    this.clock,
  });

  final String channelId;
  final VoidCallback onJoin;
  final VoidCallback onOpenCanvas;
  final String? errorMessage;
  final bool canRetry;

  /// The call this device just hung up here, shown above the join bar.
  final CallRecap? recap;

  /// Now, in epoch milliseconds; a test pins it.
  final int Function()? clock;

  static List<api.VoiceCall> _finishedCalls(List<api.VoiceCall>? calls) => [
    for (final call in calls ?? const <api.VoiceCall>[])
      if (!call.ongoing) call,
  ];

  static api.VoiceCall? _selectedCall(
    List<api.VoiceCall> calls,
    int? selectedAt,
  ) {
    if (calls.isEmpty) return null;
    return calls.firstWhere(
      (c) => c.startedAt == selectedAt,
      orElse: () => calls.first,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    final now = (clock ?? () => DateTime.now().millisecondsSinceEpoch)();
    final history = ref.watch(voiceCallHistoryProvider(channelId));
    // Newest first, so a call still going (someone stayed after you left) leads.
    final calls = history.valueOrNull?.calls ?? const <api.VoiceCall>[];
    final finished = _finishedCalls(calls);
    final selectedAt = ref.watch(selectedVoiceCallProvider(channelId));
    final shown = _selectedCall(calls, selectedAt);
    final ended = recap;
    final sections = <Widget>[
      if (ended != null && ended.isWorthShowing)
        CallRecapCard(recap: ended, title: 'Call ended'),
      VoiceJoinBar(
        rejoin: ended != null,
        channelId: channelId,
        compact: compact,
        lastCallAt: finished.isEmpty ? null : finished.first.endedAt,
        now: now,
        onJoin: onJoin,
        errorMessage: errorMessage,
        canRetry: canRetry,
      ),
      // History is secondary: a failed load leaves it out rather than stacking a second error under a join failure.
      if (shown != null) ...[
        _LastCall(
          call: shown,
          now: now,
          compact: compact,
          latest: identical(shown, calls.first),
        ),
        _Moments(
          call: shown,
          now: now,
          compact: compact,
          canvasObjectCount: history.valueOrNull?.canvasObjectCount ?? 0,
          onOpenCanvas: onOpenCanvas,
        ),
      ],
      if (calls.length > 1)
        _Earlier(
          channelId: channelId,
          calls: calls,
          selectedAt: shown?.startedAt,
          retentionDays: history.valueOrNull?.retentionDays ?? 30,
          now: now,
          compact: compact,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.all(compact ? AppSpacing.s16 : AppSpacing.s24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, section) in sections.indexed) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.s24),
                  section,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.detail, this.trailing});

  final String title;
  final String? detail;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            title,
            style: AppText.ui.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: Text(
                detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.code.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
          if (detail == null) const Spacer(),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.s12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Below this the name column and five clock labels no longer fit.
const double _fullTimelineWidth = 520;

class _LastCall extends ConsumerWidget {
  const _LastCall({
    required this.call,
    required this.now,
    required this.compact,
    required this.latest,
  });

  final api.VoiceCall call;
  final int now;
  final bool compact;

  /// The most recent call, rather than one picked from the history.
  final bool latest;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      LayoutBuilder(builder: (context, box) => _build(context, ref, box));

  Widget _build(BuildContext context, WidgetRef ref, BoxConstraints box) {
    // The pane shares the window with the chat panel, so its own width decides.
    final compact = this.compact || box.maxWidth < _fullTimelineWidth;
    final model = CallTimelineModel.from(call, now: now);
    final use24 = watchUse24Hour(ref, context);
    String clock(int at) =>
        formatClock(DateTime.fromMillisecondsSinceEpoch(at), use24Hour: use24);
    final day = callDayLabel(call.startedAt, now: now);
    final end = model.ongoing ? 'now' : clock(model.endedAt);
    final detail = compact
        ? '$day · ${formatSpanShort(model.lengthMs)}'
        : '$day · ${clock(model.startedAt)}–$end · '
              '${formatSpan(model.lengthMs)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: model.ongoing
              ? 'This call'
              : latest
              ? 'Last call'
              : 'Call',
          detail: detail,
          trailing: compact ? null : const CallTimelineLegend(),
        ),
        CallTimelineView(model: model, compact: compact),
      ],
    );
  }
}

class _Moments extends StatelessWidget {
  const _Moments({
    required this.call,
    required this.now,
    required this.compact,
    required this.canvasObjectCount,
    required this.onOpenCanvas,
  });

  final api.VoiceCall call;
  final int now;
  final bool compact;
  final int canvasObjectCount;
  final VoidCallback onOpenCanvas;

  @override
  Widget build(BuildContext context) {
    final moments = CallTimelineModel.from(call, now: now).moments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'What happened',
          detail: compact
              ? null
              : '${moments.length} ${moments.length == 1 ? 'moment' : 'moments'}',
        ),
        CallMomentsView(
          moments: moments,
          canvasObjectCount: canvasObjectCount,
          onOpenCanvas: onOpenCanvas,
          collapsedTo: compact ? 4 : null,
        ),
      ],
    );
  }
}

class _Earlier extends ConsumerWidget {
  const _Earlier({
    required this.channelId,
    required this.calls,
    required this.selectedAt,
    required this.retentionDays,
    required this.now,
    required this.compact,
  });

  final String channelId;
  final List<api.VoiceCall> calls;
  final int? selectedAt;
  final int retentionDays;
  final int now;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name =
        ref.watch(channelByIdProvider(channelId)).valueOrNull?.name ??
        'this channel';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Earlier in #$name',
          detail: compact
              ? null
              : 'kept $retentionDays days · nothing is recorded',
        ),
        CallHistoryRows(
          compact: compact,
          calls: calls,
          selectedStartedAt: selectedAt,
          now: now,
          onSelect: (startedAt) =>
              ref.read(selectedVoiceCallProvider(channelId).notifier).state =
                  startedAt,
        ),
      ],
    );
  }
}
