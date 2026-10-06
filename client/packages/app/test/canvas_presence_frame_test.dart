// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One resolution of the call tiles per build, shared by the front layer and
/// the sent-to-back backdrop, so their mounted sets cannot drift apart.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_presence_frame.dart';
import 'package:slimm_app/src/screens/canvas/canvas_presence_geometry.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

VoiceParticipant _p(String id, {bool screen = false, bool local = false}) =>
    VoiceParticipant(
      identity: id,
      name: id,
      isSpeaking: false,
      isMuted: false,
      isLocal: local,
      isScreenSharing: screen,
      isCameraOn: true,
    );

CanvasPresenceFrame _resolve(
  CanvasPresenceFrameResolver resolver,
  CanvasDocument document,
  CanvasPresenceTileOverrides overrides,
  List<VoiceParticipant> participants,
) => resolver.resolve(
  participants: participants,
  document: document,
  overrides: overrides,
  layout: const CanvasPresenceLayout(),
  hideSelfCamera: false,
);

void main() {
  late CanvasDocument document;
  late CanvasPresenceTileOverrides overrides;

  setUp(() {
    document = CanvasDocument()..setViewport(const Size(1000, 800));
    overrides = CanvasPresenceTileOverrides();
  });

  tearDown(() {
    document.dispose();
    overrides.dispose();
  });

  test('no participants resolve to an empty frame', () {
    final frame = _resolve(
      CanvasPresenceFrameResolver(),
      document,
      overrides,
      const [],
    );

    expect(frame.keys, isEmpty);
    expect(frame.onCanvas, isEmpty);
    expect(frame.visibleIds, isEmpty);
  });

  test('the frame carries keys, rects and the visible subset', () {
    overrides
      ..setRect('camera:near', const Rect.fromLTWH(10, 10, 100, 80))
      ..setRect('camera:far', const Rect.fromLTWH(5000, 5000, 100, 80));

    final frame = _resolve(CanvasPresenceFrameResolver(), document, overrides, [
      _p('near'),
      _p('far'),
    ]);

    expect(frame.keys, {'camera:near', 'camera:far'});
    expect(frame.onCanvas.keys, frame.keys);
    expect(frame.visibleIds, {'camera:near'});
    expect(frame.byIdentity.keys, {'near', 'far'});
  });

  test('asking twice with the same input gives the same visible set', () {
    overrides.setRect('camera:edge', const Rect.fromLTWH(1100, 10, 100, 80));
    final resolver = CanvasPresenceFrameResolver();
    final people = [_p('edge')];

    final first = _resolve(resolver, document, overrides, people);
    final second = _resolve(resolver, document, overrides, people);

    expect(second.visibleIds, first.visibleIds);
  });

  test('a mounted tile stays until it leaves the wider exit band', () {
    overrides.setRect('camera:t', const Rect.fromLTWH(10, 10, 100, 80));
    final resolver = CanvasPresenceFrameResolver();
    final people = [_p('t')];
    expect(_resolve(resolver, document, overrides, people).visibleIds, {
      'camera:t',
    });

    overrides.setRect('camera:t', const Rect.fromLTWH(1400, 10, 100, 80));
    expect(_resolve(resolver, document, overrides, people).visibleIds, {
      'camera:t',
    }, reason: 'inside the exit band, outside the enter band');

    overrides.setRect('camera:t', const Rect.fromLTWH(2500, 10, 100, 80));
    expect(_resolve(resolver, document, overrides, people).visibleIds, isEmpty);
  });

  test('screen and camera labels read the same everywhere', () {
    expect(presenceScreenLabel(_p('ann', local: true)), 'Your screen');
    expect(presenceScreenLabel(_p('ann')), "ann's screen");
  });
}
