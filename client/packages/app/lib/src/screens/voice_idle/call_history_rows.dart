// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Earlier in #channel": the calls before the one on show, one 40px row
/// each (design 13), tapping one swaps it into the timeline.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../format.dart';
import '../../providers/display_preferences.dart';
import '../../features/members/providers/user_profiles.dart';
import '../../features/members/widgets/user_avatar.dart';
import 'call_timeline_model.dart';

class CallHistoryRows extends StatelessWidget {
  const CallHistoryRows({
    super.key,
    required this.calls,
    required this.selectedStartedAt,
    required this.onSelect,
    required this.now,
  });

  final List<api.VoiceCall> calls;
  final int? selectedStartedAt;
  final ValueChanged<int> onSelect;
  final int now;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final call in calls)
        _HistoryRow(
          model: CallTimelineModel.from(call, now: now),
          selected: call.startedAt == selectedStartedAt,
          onTap: () => onSelect(call.startedAt),
          now: now,
        ),
    ],
  );
}

class _HistoryRow extends ConsumerStatefulWidget {
  const _HistoryRow({
    required this.model,
    required this.selected,
    required this.onTap,
    required this.now,
  });

  final CallTimelineModel model;
  final bool selected;
  final VoidCallback onTap;
  final int now;

  @override
  ConsumerState<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends ConsumerState<_HistoryRow> {
  bool _hovered = false;
  bool _focused = false;

  CallTimelineModel get model => widget.model;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final use24 = watchUse24Hour(ref, context);
    String clock(int at) =>
        formatClock(DateTime.fromMillisecondsSinceEpoch(at), use24Hour: use24);
    final note = _note(ref);
    final day = callDayLabel(model.startedAt, now: widget.now, short: true);
    return Semantics(
      button: true,
      selected: widget.selected,
      label:
          'Call on ${callDayLabel(model.startedAt, now: widget.now)}, '
          '${formatSpan(model.lengthMs)}',
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => widget.onTap(),
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: AppSpacing.s40,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            decoration: BoxDecoration(
              color: widget.selected || _hovered
                  ? tokens.surfaceRaised
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: _focused ? Border.all(color: tokens.focusRing) : null,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: AppSpacing.s40 + AppSpacing.s8,
                  child: Text(
                    day,
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                ),
                Text(
                  '${clock(model.startedAt)}–${clock(model.endedAt)}',
                  style: AppText.code.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(width: AppSpacing.s12),
                Text(
                  formatSpanShort(model.lengthMs),
                  style: AppText.code.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(width: AppSpacing.s12),
                _StackedAvatars(
                  userIds: [for (final l in model.lanes) l.userId],
                ),
                const SizedBox(width: AppSpacing.s12),
                Expanded(
                  child: Text(
                    note ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The one thing worth noting: the longest share, else the canvas.
  String? _note(WidgetRef ref) {
    CallLane? sharer;
    for (final lane in model.lanes) {
      if (lane.sharedMs > (sharer?.sharedMs ?? 0)) sharer = lane;
    }
    if (sharer != null) {
      final name =
          ref
              .watch(userProfileProvider(sharer.userId))
              .valueOrNull
              ?.displayName ??
          'Someone';
      return '$name shared ${formatSpanShort(sharer.sharedMs)}';
    }
    final canvas = model.moments.where((m) => m.kind == CallMomentKind.canvas);
    if (canvas.isEmpty) return null;
    final images = canvas
        .where((m) => m.canvasKind == 'image' || m.canvasKind == 'gif')
        .fold(0, (sum, m) => sum + m.count);
    if (images > 0) {
      return 'canvas: $images ${images == 1 ? 'image' : 'images'}';
    }
    return 'canvas: drawing';
  }
}

class _StackedAvatars extends ConsumerWidget {
  const _StackedAvatars({required this.userIds});

  final List<String> userIds;

  static const _max = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = userIds.take(_max).toList();
    const size = AppAvatarSize.s20;
    const step = size * 0.7;
    return SizedBox(
      width: shown.isEmpty ? 0 : size + step * (shown.length - 1),
      height: size,
      child: Stack(
        children: [
          for (final (i, id) in shown.indexed)
            Positioned(
              left: step * i,
              child: UserAvatar(
                name:
                    ref
                        .watch(userProfileProvider(id))
                        .valueOrNull
                        ?.displayName ??
                    '',
                userId: id,
                size: size,
              ),
            ),
        ],
      ),
    );
  }
}

/// "today", "yesterday", "Sat" or "12 Oct" for a call's start; [short] keeps
/// it to the weekday form for a row.
String callDayLabel(int epochMs, {required int now, bool short = false}) {
  final day = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final today = DateTime.fromMillisecondsSinceEpoch(now);
  final startOfToday = DateTime(today.year, today.month, today.day);
  final startOfDay = DateTime(day.year, day.month, day.day);
  final daysAgo = startOfToday.difference(startOfDay).inDays;
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (daysAgo <= 0) return short ? 'Today' : 'today';
  if (daysAgo == 1) return short ? 'Yest.' : 'yesterday';
  if (daysAgo < 7) return weekdays[day.weekday - 1];
  return '${day.day} ${months[day.month - 1]}';
}
