// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thin playback bar with elapsed and total, extrapolated from the sender's
/// last sampled position. The timer exists only while this is mounted, and
/// stops at the end of the track.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// The wall clock, overridden in tests so no real time passes.
final activityClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

const _tick = Duration(seconds: 1);
const _barHeight = 3.0;

/// `m:ss`, or `h:mm:ss` from an hour up.
String formatTrackTime(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

class ActivityProgressBar extends ConsumerStatefulWidget {
  const ActivityProgressBar({super.key, required this.progress});

  final api.ActivityProgress progress;

  @override
  ConsumerState<ActivityProgressBar> createState() => _State();
}

class _State extends ConsumerState<ActivityProgressBar> {
  Timer? _timer;
  late int _position;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ActivityProgressBar old) {
    super.didUpdateWidget(old);
    if (old.progress != widget.progress) _sync();
  }

  void _sync() {
    _position = _now();
    _timer?.cancel();
    _timer = null;
    if (_position >= widget.progress.durationMs) return;
    _timer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      final next = _now();
      setState(() => _position = next);
      if (next >= widget.progress.durationMs) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  int _now() => widget.progress.positionAt(
    ref.read(activityClockProvider)().millisecondsSinceEpoch,
  );

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final duration = widget.progress.durationMs;
    return Row(
      spacing: AppSpacing.s8,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_barHeight),
            child: LinearProgressIndicator(
              key: const Key('activity-progress'),
              value: _position / duration,
              minHeight: _barHeight,
              color: tokens.accent,
              backgroundColor: tokens.borderSubtle,
            ),
          ),
        ),
        Text(
          '${formatTrackTime(_position)} / ${formatTrackTime(duration)}',
          key: const Key('activity-progress-time'),
          style: AppText.caption.copyWith(
            color: tokens.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
