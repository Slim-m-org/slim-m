// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Naming the camera and screen-share tiles a viewer has hidden on their own
/// canvas, for the dock's own recovery list.
///
/// A hide must stay reversible without leaving the call, or it is a delete
/// wearing a softer name - so the overflow menu lists every hidden tile by a
/// name a person recognises rather than by the raw `'camera:<identity>'` key
/// the override map is actually stored under. Split out of
/// `canvas_pane_body.dart`, which had no room left under the file budget and
/// no reason to carry a pure list-building function anyway.
library;

import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_geometry.dart'
    show presenceScreenLabel, presenceTileIdentity, presenceTileKind;
import 'canvas_tools_row.dart' show CanvasHiddenTile;

/// Every hidden tile belonging to somebody still on the call, sorted by the
/// label a person reads rather than by the key it is stored under.
///
/// A key naming somebody who has since left is dropped: there is nothing to
/// restore them to, and the roster is what decides a tile exists at all. The
/// caller's own camera can be hidden through its on-tile control the same as
/// anyone else's, so it appears here too - distinct from the standing
/// "never show my own camera" preference, which has its own toggle and its
/// own way back.
List<CanvasHiddenTile> hiddenCanvasTiles({
  required List<VoiceParticipant> participants,
  required CanvasPresenceTileOverrides overrides,
}) {
  final byIdentity = {for (final p in participants) p.identity: p};
  final tiles = <CanvasHiddenTile>[];
  for (final key in overrides.hiddenKeys) {
    final participant = byIdentity[presenceTileIdentity(key)];
    if (participant == null) continue;
    final isScreen = presenceTileKind(key) == screenTrackKind;
    final label = isScreen
        ? '${presenceScreenLabel(participant)} share'
        : (participant.isLocal
              ? 'Your camera'
              : "${participant.name}'s camera");
    tiles.add(CanvasHiddenTile(key: key, label: label));
  }
  tiles.sort((a, b) => a.label.compareTo(b.label));
  return tiles;
}
