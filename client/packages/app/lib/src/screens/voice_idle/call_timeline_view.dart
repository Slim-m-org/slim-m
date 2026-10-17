// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The last call as a lane per person (design 13, decision 0066): grey while
/// they were in, accent while they shared, a warning tick where they left
/// before the end, and the call's times along the bottom.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../format.dart';
import '../../providers/display_preferences.dart';
import '../../providers/providers.dart';
import '../../features/members/providers/user_profiles.dart';
import '../../features/members/widgets/user_avatar.dart';
import 'call_timeline_model.dart';

const double _laneHeight = 10;

class CallTimelineView extends ConsumerWidget {
  const CallTimelineView({
    super.key,
    required this.model,
    this.compact = false,
  });

  final CallTimelineModel model;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final use24 = watchUse24Hour(ref, context);
    final selfId = ref.watch(sessionProvider).tokens?.userId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final lane in model.lanes)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s8),
            child: _LaneRow(
              lane: lane,
              model: model,
              isSelf: lane.userId == selfId,
              compact: compact,
            ),
          ),
        Row(
          children: [
            SizedBox(width: compact ? AppAvatarSize.s24 : _nameColumnWidth),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final at in model.ticks(compact ? 3 : 5))
                    Text(
                      formatClock(
                        DateTime.fromMillisecondsSinceEpoch(at),
                        use24Hour: use24,
                      ),
                      style: AppText.code.copyWith(color: tokens.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

const double _nameColumnWidth = 176;

class _LaneRow extends ConsumerWidget {
  const _LaneRow({
    required this.lane,
    required this.model,
    required this.isSelf,
    required this.compact,
  });

  final CallLane lane;
  final CallTimelineModel model;
  final bool isSelf;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name =
        ref.watch(userProfileProvider(lane.userId)).valueOrNull?.displayName ??
        '';
    final avatar = UserAvatar(
      name: name,
      userId: lane.userId,
      size: AppAvatarSize.s24,
    );
    final bar = Semantics(
      label: _describe(name),
      excludeSemantics: true,
      child: SizedBox(
        height: _laneHeight,
        child: CustomPaint(
          painter: _LanePainter(
            lane: lane,
            model: model,
            inCall: tokens.borderStrong,
            sharing: tokens.accentFill,
            left: tokens.warnText,
            track: tokens.surfaceSunken,
          ),
        ),
      ),
    );
    if (compact) {
      return Row(
        children: [
          avatar,
          const SizedBox(width: AppSpacing.s8),
          Expanded(child: bar),
        ],
      );
    }
    final detail = [
      if (isSelf) 'you',
      formatSpanShort(lane.inMs),
      if (lane.sharedMs > 0) 'shared ${formatSpanShort(lane.sharedMs)}',
    ].join(' · ');
    return Row(
      children: [
        SizedBox(
          width: _nameColumnWidth,
          child: Row(
            children: [
              avatar,
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui.copyWith(color: tokens.textPrimary),
                    ),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(child: bar),
      ],
    );
  }

  String _describe(String name) {
    final parts = ['$name was in the call for ${formatSpan(lane.inMs)}'];
    if (lane.sharedMs > 0) {
      parts.add('shared a screen for ${formatSpan(lane.sharedMs)}');
    }
    if (lane.leftEarlyAt != null) parts.add('left before the end');
    return parts.join(', ');
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter({
    required this.lane,
    required this.model,
    required this.inCall,
    required this.sharing,
    required this.left,
    required this.track,
  });

  final CallLane lane;
  final CallTimelineModel model;
  final Color inCall;
  final Color sharing;
  final Color left;
  final Color track;

  double _x(int at, Size size) {
    final length = model.lengthMs <= 0 ? 1 : model.lengthMs;
    return ((at - model.startedAt) / length).clamp(0.0, 1.0) * size.width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, radius),
      Paint()..color = track,
    );
    void span(Span s, Color color, double inset) {
      final rect = Rect.fromLTRB(
        _x(s.from, size),
        inset,
        _x(s.to, size).clamp(_x(s.from, size) + 2, size.width),
        size.height - inset,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
        Paint()..color = color,
      );
    }

    for (final s in lane.inCall) {
      span(s, inCall, 0);
    }
    for (final s in lane.sharing) {
      span(s, sharing, 0);
    }
    final leftAt = lane.leftEarlyAt;
    if (leftAt != null) {
      final x = _x(leftAt, size);
      canvas.drawLine(
        Offset(x, -2),
        Offset(x, size.height + 2),
        Paint()
          ..color = left
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_LanePainter old) =>
      old.lane != lane ||
      old.model != model ||
      old.inCall != inCall ||
      old.sharing != sharing ||
      old.left != left ||
      old.track != track;
}

/// The three marks a lane uses, named.
class CallTimelineLegend extends StatelessWidget {
  const CallTimelineLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    Widget swatch(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: AppSpacing.s12,
          height: AppSpacing.s8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        const SizedBox(width: AppSpacing.s4),
        Text(
          label,
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
    return Wrap(
      spacing: AppSpacing.s12,
      children: [
        swatch(tokens.borderStrong, 'in call'),
        swatch(tokens.accentFill, 'sharing'),
        swatch(tokens.warnText, 'left'),
      ],
    );
  }
}
