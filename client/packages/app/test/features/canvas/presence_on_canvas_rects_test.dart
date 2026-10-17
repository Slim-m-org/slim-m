// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `presenceOnCanvasRects` is the one place both presence widgets read a tile's
/// world rect from, so a control never manipulates a different box than the one
/// painted. Three rules decide what it returns and none were tested: a hidden
/// tile is dropped, this viewer's own camera is dropped when hideSelfCamera is
/// set, and a tile the viewer has dragged uses its override rect over the
/// layout default.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

VoiceParticipant _p(String identity, {bool local = false}) => VoiceParticipant(
  identity: identity,
  name: identity,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

void main() {
  final layout = const CanvasPresenceLayout();

  test('a hidden tile is dropped, the rest keep their default rect', () {
    final me = _p('me');
    final them = _p('them');
    final keys = presenceTileKeys([me, them]);
    final byIdentity = {'me': me, 'them': them};
    final overrides = CanvasPresenceTileOverrides();
    final hidden = keys.firstWhere((k) => presenceTileIdentity(k) == 'me');
    overrides.setHidden(hidden, true);

    final rects = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: overrides,
      byIdentity: byIdentity,
      hideSelfCamera: false,
    );

    expect(rects.containsKey(hidden), isFalse);
    expect(rects, hasLength(1));
  });

  test('hideSelfCamera drops this viewer\'s own camera, not a remote one', () {
    final me = _p('me', local: true);
    final them = _p('them');
    final keys = presenceTileKeys([me, them]);
    final byIdentity = {'me': me, 'them': them};

    final shown = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: CanvasPresenceTileOverrides(),
      byIdentity: byIdentity,
      hideSelfCamera: true,
    );

    expect(shown.keys.map(presenceTileIdentity), ['them']);

    // Without the flag, the local camera is back.
    final all = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: CanvasPresenceTileOverrides(),
      byIdentity: byIdentity,
      hideSelfCamera: false,
    );
    expect(all, hasLength(2));
  });

  test('a dragged tile uses its override rect over the layout default', () {
    final them = _p('them');
    final keys = presenceTileKeys([them]);
    final byIdentity = {'them': them};
    final overrides = CanvasPresenceTileOverrides();
    final key = keys.single;
    overrides.setRect(key, const Rect.fromLTWH(500, 600, 220, 160));

    final rects = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: overrides,
      byIdentity: byIdentity,
      hideSelfCamera: false,
    );

    expect(rects[key], overrides.stateFor(key).rect);
  });

  test('a viewport big enough for every untouched tile keeps the layout\'s '
      'own margin-anchored default, unchanged', () {
    final camera = _p('camera-user');
    final sharing = const VoiceParticipant(
      identity: 'screen-user',
      name: 'screen-user',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: true,
    );
    final keys = presenceTileKeys([camera, sharing]);
    final byIdentity = {'camera-user': camera, 'screen-user': sharing};

    final rects = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: CanvasPresenceTileOverrides(),
      byIdentity: byIdentity,
      hideSelfCamera: false,
      viewport: const Size(1200, 800),
    );

    // A screen-sharer keeps a camera tile too: camera, sharer's camera, share.
    expect(rects, hasLength(3));
    final values = rects.values.toList();
    for (var i = 0; i < values.length; i++) {
      for (var j = i + 1; j < values.length; j++) {
        expect(values[i].overlaps(values[j]), isFalse);
      }
    }
    expect(values.map((r) => r.left).reduce(math.min), 24);
  });

  test('a pane too narrow for every untouched tile shifts the whole block '
      'left so the block stops running past the pane edge', () {
    final sharing = const VoiceParticipant(
      identity: 'screen-user',
      name: 'screen-user',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: true,
    );
    // One sharer: a 140-wide camera tile plus a 360-wide screen tile, a 548-wide block, wider than the 530-wide pane below.
    final keys = presenceTileKeys([sharing]);
    final byIdentity = {'screen-user': sharing};

    final rects = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: CanvasPresenceTileOverrides(),
      byIdentity: byIdentity,
      hideSelfCamera: false,
      viewport: const Size(530, 800),
    );

    expect(rects, hasLength(2));
    final values = rects.values.toList();
    expect(values[0].overlaps(values[1]), isFalse);
    for (final rect in values) {
      expect(
        rect.right,
        lessThanOrEqualTo(530),
        reason: 'shifted left so nothing still runs past the pane edge',
      );
    }
  });

  test('an empty or not-yet-measured viewport falls back to the layout '
      'default rather than collapsing every tile onto itself', () {
    final me = _p('me');
    final keys = presenceTileKeys([me]);
    final byIdentity = {'me': me};

    final rects = presenceOnCanvasRects(
      keys: keys,
      layout: layout,
      overrides: CanvasPresenceTileOverrides(),
      byIdentity: byIdentity,
      hideSelfCamera: false,
      viewport: Size.zero,
    );

    expect(rects[keys.single]!.topLeft, const Offset(24, 24));
  });
}
