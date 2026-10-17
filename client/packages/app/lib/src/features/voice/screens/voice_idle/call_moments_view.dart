// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "What happened": the last call's moments in order (design 13), each a
/// time and one plain sentence, ending with the canvas it left behind.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../../format.dart';
import '../../../settings/providers/display_preferences.dart';
import '../../../members/providers/user_profiles.dart';
import 'call_timeline_model.dart';

class CallMomentsView extends ConsumerStatefulWidget {
  const CallMomentsView({
    super.key,
    required this.moments,
    required this.canvasObjectCount,
    required this.onOpenCanvas,
    this.collapsedTo,
  });

  final List<CallMoment> moments;
  final int canvasObjectCount;
  final VoidCallback onOpenCanvas;

  /// On a phone, how many moments show before "N more".
  final int? collapsedTo;

  @override
  ConsumerState<CallMomentsView> createState() => _CallMomentsViewState();
}

class _CallMomentsViewState extends ConsumerState<CallMomentsView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final limit = widget.collapsedTo;
    final shown = limit == null || _expanded
        ? widget.moments
        : widget.moments.take(limit).toList();
    final hidden = widget.moments.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final moment in shown)
          _MomentRow(
            moment: moment,
            canvasObjectCount: widget.canvasObjectCount,
            onOpenCanvas: widget.onOpenCanvas,
          ),
        if (hidden > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: '$hidden more',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: () => setState(() => _expanded = true),
            ),
          ),
        if (widget.moments.isEmpty)
          Text(
            'Nothing else happened in this call.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
  }
}

class _MomentRow extends ConsumerWidget {
  const _MomentRow({
    required this.moment,
    required this.canvasObjectCount,
    required this.onOpenCanvas,
  });

  final CallMoment moment;
  final int canvasObjectCount;
  final VoidCallback onOpenCanvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final names = [
      for (final id in moment.userIds)
        ref.watch(userProfileProvider(id)).valueOrNull?.displayName ??
            'Someone',
    ];
    final time = formatClock(
      DateTime.fromMillisecondsSinceEpoch(moment.at),
      use24Hour: watchUse24Hour(ref, context),
    );
    final opensCanvas =
        moment.kind == CallMomentKind.ended && canvasObjectCount > 0;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.s32),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: AppSpacing.s40 * 2,
            child: Text(
              time,
              style: AppText.code.copyWith(color: tokens.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              momentSentence(moment, names, canvasObjectCount),
              style: AppText.ui.copyWith(color: tokens.textPrimary),
            ),
          ),
          if (opensCanvas)
            AppButton(
              label: 'Open canvas',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: onOpenCanvas,
            ),
        ],
      ),
    );
  }
}

/// The one sentence a moment reads as, from the names of the people in it.
String momentSentence(
  CallMoment moment,
  List<String> names,
  int canvasObjectCount,
) {
  final who = switch (names.length) {
    0 => 'Someone',
    1 => names.single,
    2 => '${names[0]} and ${names[1]}',
    _ => '${names.take(names.length - 1).join(', ')} and ${names.last}',
  };
  return switch (moment.kind) {
    CallMomentKind.started => '$who started the call',
    CallMomentKind.joined => '$who joined',
    CallMomentKind.left => '$who left',
    CallMomentKind.shared =>
      '$who shared a screen · ${formatSpan(moment.durationMs ?? 0)}',
    CallMomentKind.canvas => _canvasSentence(who, moment),
    CallMomentKind.ended =>
      canvasObjectCount > 0
          ? 'Call ended · canvas kept $canvasObjectCount '
                '${canvasObjectCount == 1 ? 'object' : 'objects'}'
          : 'Call ended',
  };
}

String _canvasSentence(String who, CallMoment moment) {
  final n = moment.count;
  return switch (moment.canvasKind) {
    'stroke' => '$who drew on the canvas · $n ${n == 1 ? 'stroke' : 'strokes'}',
    'image' =>
      n == 1
          ? '$who pasted an image to the canvas'
          : '$who pasted $n images to the canvas',
    'gif' =>
      n == 1
          ? '$who added a GIF to the canvas'
          : '$who added $n GIFs to the canvas',
    _ =>
      n == 1
          ? '$who put something on the canvas'
          : '$who put $n things on the canvas',
  };
}
