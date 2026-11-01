// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who can be followed on the canvas, and where the top corner's chrome clears.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// One person who can be followed.
class CanvasFollowTarget {
  const CanvasFollowTarget(this.id, this.name);

  final String id;
  final String name;
}

/// Everyone else on the canvas or its call, one entry each, in a stable order.
List<CanvasFollowTarget> canvasFollowTargets({
  required Iterable<CanvasCursor> cursors,
  required Iterable<VoiceParticipant> participants,
  required String? selfId,
}) {
  final byId = <String, CanvasFollowTarget>{
    for (final c in cursors) c.id: CanvasFollowTarget(c.id, c.label),
    for (final p in participants)
      if (!p.isLocal) p.identity: CanvasFollowTarget(p.identity, p.name),
  }..remove(selfId);
  return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
}

/// Clears the top-left corner's rows: two rows of 44 at touch size, two of 28 otherwise.
double canvasCornerRowsInset(BuildContext context) =>
    AppTouchTargets.of(context)
    ? AppSpacing.s12 + 2 * AppSizes.rowTouch + 2 * AppSpacing.s8
    : AppSpacing.s64;
