// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure geometry shared between [CanvasPresenceLayer] (the interactive
/// shell every tile's controls live on) and [CanvasPresenceBackdrop] (the
/// non-interactive paint of a tile sent to the back) - both need the exact
/// same rects, on the same viewport, or a control could drift from the
/// pixels it is meant to be manipulating. See `canvas_presence_layer.dart`'s
/// own doc for why depth needs two widgets at all.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

typedef CameraViewBuilder = Widget Function(String identity);
typedef ScreenShareViewBuilder = Widget Function(String identity);

const presenceCameraOnSize = Size(220, 160);
const presenceCameraOffSize = Size(140, 140);
const presenceScreenShareSize = Size(360, 203);

/// Every tile key this call's roster has right now: one camera per
/// participant, plus a screen tile for whoever is sharing.
///
/// Built through `videoSubscriptionKey` rather than by string interpolation
/// here, because these same keys are what `VoiceSession.setVideoInterest`
/// matches remote video publications against; see that function's own doc
/// for why one shared builder beats two agreeing literals.
Set<String> presenceTileKeys(List<VoiceParticipant> participants) {
  final keys = <String>{};
  for (final p in participants) {
    keys.add(videoSubscriptionKey(identity: p.identity, screenShare: false));
    if (p.isScreenSharing) {
      keys.add(videoSubscriptionKey(identity: p.identity, screenShare: true));
    }
  }
  return keys;
}

/// `'screen'` or `'camera'` - the same two strings the server's own
/// `CanvasMediaSlot.kind` uses, so a key can be sent straight through with
/// no translation.
String presenceTileKind(String key) => videoSubscriptionKind(key);

/// The tile key for a server slot of [kind] held by [userId], built through
/// the one `videoSubscriptionKey` so slots line up with `presenceTileKeys`.
String presenceTileKeyForSlot(String kind, String userId) =>
    videoSubscriptionKey(
      identity: userId,
      screenShare: kind == screenTrackKind,
    );

/// "Your screen" or "the name's screen", the one label for a screen-share tile.
String presenceScreenLabel(VoiceParticipant participant) =>
    participant.isLocal ? 'Your screen' : "${participant.name}'s screen";

/// The participant a tile key names, stripped of its `kind:` prefix.
String presenceTileIdentity(String key) => key.substring(key.indexOf(':') + 1);

Size presenceTileSize(String key, Map<String, VoiceParticipant> byIdentity) {
  if (presenceTileKind(key) == screenTrackKind) return presenceScreenShareSize;
  final participant = byIdentity[presenceTileIdentity(key)];
  return (participant?.isCameraOn ?? false)
      ? presenceCameraOnSize
      : presenceCameraOffSize;
}

/// Whether [key] has nothing but [CanvasPresenceBubble]'s avatar fallback to
/// show right now - always false for a screen-share tile (which only ever
/// exists while a real share is live), true for a camera tile whose
/// participant's camera is off. The one predicate `canvas_presence_layer
/// .dart` and `canvas_presence_backdrop.dart` both consult before deciding
/// whether resize, lock and depth even apply to a tile, so the two widgets
/// can never disagree about which kind a key currently is.
bool presenceTileIsAvatarOnly(
  String key,
  Map<String, VoiceParticipant> byIdentity,
) {
  if (presenceTileKind(key) == screenTrackKind) return false;
  return !(byIdentity[presenceTileIdentity(key)]?.isCameraOn ?? false);
}

/// [overrides]'s own answer for whether [key] is sent to back, forced to
/// `false` for an avatar-only tile: depth exists so ink can land over or
/// under a video track, and an avatar-only tile has no video to draw
/// relative to - see `canvas_presence_bubble.dart`'s own doc on
/// [canvasAvatarMarkerSize]. Consulting this everywhere `sentToBack` is read
/// keeps a legacy `true` from a since-turned-off camera from either
/// resurrecting the depth toggle or, worse, letting the layer and the
/// backdrop both paint the same tile's real content at once.
bool presenceEffectiveSentToBack(
  String key,
  CanvasPresenceTileOverrides overrides,
  Map<String, VoiceParticipant> byIdentity,
) => !presenceTileIsAvatarOnly(key, byIdentity) && overrides.sentToBackFor(key);

/// Every tile's current world rect - an override's own drag or resize if it
/// has one, [layout]'s default arrangement otherwise - excluding whatever is
/// hidden this call. The one place both widgets read a rect from, so a
/// control can never end up manipulating a different box than the one a
/// person sees painted.
Map<String, Rect> presenceOnCanvasRects({
  required Set<String> keys,
  required CanvasPresenceLayout layout,
  required CanvasPresenceTileOverrides overrides,
  required Map<String, VoiceParticipant> byIdentity,
  required bool hideSelfCamera,
  Size viewport = Size.zero,
}) {
  final raw = layout.arrange(
    keys,
    sizeFor: (key) => presenceTileSize(key, byIdentity),
  );
  final defaults = _clampedToViewport(raw, viewport);
  final onCanvas = <String, Rect>{};
  for (final key in keys) {
    final state = overrides.stateFor(key);
    if (state.hidden) continue;
    if (hideSelfCamera &&
        presenceTileKind(key) == cameraTrackKind &&
        byIdentity[presenceTileIdentity(key)]?.isLocal == true) {
      continue;
    }
    onCanvas[key] = state.rect ?? defaults[key]!;
  }
  return onCanvas;
}

/// [defaults] shifted left and/or up just enough that the whole untouched
/// block stops running past [viewport]'s right or bottom edge - a fix for
/// several untouched tiles landing partly cut off in a narrow canvas pane,
/// without moving anything for the common case where the block already
/// fits (every tile a single-participant test scaffold ever placed at the
/// layout's own margin, for instance). A block already wider or taller
/// than the viewport is pinned to the near edge rather than pushed further
/// negative, since there is nowhere left to show all of it.
Map<String, Rect> _clampedToViewport(
  Map<String, Rect> defaults,
  Size viewport,
) {
  if (defaults.isEmpty || viewport.width <= 0 || viewport.height <= 0) {
    return defaults;
  }
  var bounds = defaults.values.first;
  for (final rect in defaults.values.skip(1)) {
    bounds = bounds.expandToInclude(rect);
  }
  final dx = bounds.right > viewport.width
      ? math.max(viewport.width - bounds.right, -bounds.left)
      : 0.0;
  final dy = bounds.bottom > viewport.height
      ? math.max(viewport.height - bounds.bottom, -bounds.top)
      : 0.0;
  if (dx == 0.0 && dy == 0.0) return defaults;
  final offset = Offset(dx, dy);
  return defaults.map((key, rect) => MapEntry(key, rect.shift(offset)));
}

/// [keys] sorted for paint order. A sent-to-back tile always paints beneath
/// a front one (the primary key), so a back tile's own controls can never
/// sit over a front tile - the bug a `sentToBack`-blind sort left open.
/// Within each group the old rule holds: a tile this viewer has ever dragged
/// or resized paints above every untouched one, most recently touched last
/// (topmost), the same "a real sheet of paper does not slide under the pile"
/// rule regardless of which paint layer (front or backdrop) is asking.
List<String> presencePaintOrder(
  Set<String> keys,
  int? Function(String) zFor,
  bool Function(String) sentToBack,
) {
  final ordered = keys.toList(growable: false);
  final rank = <String, int>{
    for (var i = 0; i < ordered.length; i++) ordered[i]: i,
  };
  final withZ = ordered
      .map((key) => (key: key, back: sentToBack(key), z: zFor(key) ?? -1))
      .toList();
  withZ.sort((a, b) {
    if (a.back != b.back) return a.back ? -1 : 1;
    final byZ = a.z.compareTo(b.z);
    return byZ != 0 ? byZ : rank[a.key]!.compareTo(rank[b.key]!);
  });
  return [for (final entry in withZ) entry.key];
}

/// A world rect converted to screen space under [camera] - the one place
/// that arithmetic lives, so a tile's controls and its (possibly
/// backdrop-painted) content can never round differently.
Rect presenceScreenRect(Rect worldRect, Camera camera) => Rect.fromLTWH(
  (worldRect.left - camera.x) * camera.zoom,
  (worldRect.top - camera.y) * camera.zoom,
  worldRect.width * camera.zoom,
  worldRect.height * camera.zoom,
);
