// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen the next mark takes, on the board or over a shared screen alike.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/effective_me.dart';
import '../../members/widgets/profile_colour.dart' show profileColourOf;
import '../providers/canvas_pen_style.dart';

/// The pen picked this session, else the colour nearest the profile colour.
CanvasPenStyle armedPen(WidgetRef ref) {
  final chosen = ref.read(canvasActivePenStyleProvider);
  if (chosen != null) return chosen;
  final me = ref.read(meProvider).valueOrNull;
  final colour = me == null
      ? null
      : profileColourOf(index: me.profileColor, rgb: me.profileColorRgb);
  return colour == null
      ? const CanvasPenStyle()
      : CanvasPenStyle(colorKey: nearestPenColorKey(colour));
}
