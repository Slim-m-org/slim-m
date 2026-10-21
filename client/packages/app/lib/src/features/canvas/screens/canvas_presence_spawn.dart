// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a tile the local person just started appears: in front of them, so they can tell it exists.
library;

import 'dart:ui';

import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_geometry.dart';

/// Tile keys of [now]'s local participant that were not live in [before]; empty when [before] had no local participant yet, which is a reconnect rather than a start.
Set<String> presenceStartedByMe(
  List<VoiceParticipant> before,
  List<VoiceParticipant> now,
) {
  final wasHere = before.any((p) => p.isLocal);
  if (!wasHere) return const {};
  return presenceTileKeys(
    now.where((p) => p.isLocal).toList(),
  ).difference(presenceTileKeys(before.where((p) => p.isLocal).toList()));
}

/// The rect for a new tile of [key]: centred on the viewport (or the board when no viewport is known), held to the board, nudged off [taken] where that is cheap.
Rect? presenceSpawnRect(
  String key,
  CanvasDocument document, {
  Iterable<Rect> taken = const [],
}) {
  final size = presenceTileSize(key);
  final Offset? centre = document.viewport.isEmpty
      ? document.board?.center
      : document.worldView.center;
  if (centre == null) return null;
  const step = 48.0;
  Rect? first;
  for (var i = 0; i < 6; i++) {
    final at = centre + const Offset(step, step) * i.toDouble();
    final placed = document.placeOnBoard(
      Rect.fromCenter(center: at, width: size.width, height: size.height),
    );
    first ??= placed;
    if (!taken.any((other) => other.overlaps(placed))) return placed;
  }
  return first;
}
