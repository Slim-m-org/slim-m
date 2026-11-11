// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Playing for 12 min": how long a game has been running, redrawn each
/// minute while it is on screen (decision 0115).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/presence_activity.dart';

class ActivityElapsed extends ConsumerStatefulWidget {
  const ActivityElapsed({super.key, required this.startedAt});

  /// Epoch milliseconds the game began.
  final int startedAt;

  @override
  ConsumerState<ActivityElapsed> createState() => _ActivityElapsedState();
}

class _ActivityElapsedState extends ConsumerState<ActivityElapsed> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(
      const Duration(minutes: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final started = DateTime.fromMillisecondsSinceEpoch(widget.startedAt);
    final elapsed = ref.watch(activityClockProvider)().difference(started);
    return Text(
      formatPlayTime(elapsed),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
  }
}
