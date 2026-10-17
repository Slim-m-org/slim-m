// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasPresenceLayer]'s `onVideoInterest`: which tiles the canvas tells
/// the live session are worth subscribing remote video for.
///
/// Every assertion here is on the *set* reported, not on whether a callback
/// fired, because a report that fires with the wrong contents is the failure
/// that would actually reach a person - as a tile going black while it is on
/// screen, or a call quietly paying for video nobody can see.
///
/// The band this exercises is `CanvasPresenceVisibility`'s own, unchanged by
/// this feature: the interest set is exactly the set of tiles this widget
/// just mounted, never a second opinion computed beside it, which is the
/// property `canvas_presence_layer.dart`'s own doc calls out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: true,
  isLocal: false,
  isScreenSharing: false,
);

const _ada = VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: true,
  isLocal: false,
  isScreenSharing: true,
);

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

Widget _noView(String identity) => const SizedBox();

/// Records every interest set reported, newest last.
class _Reports {
  final List<Set<String>?> reported = [];
  Set<String>? get last => reported.isEmpty ? null : reported.last;
  void call(Set<String>? keys) => reported.add(keys);
}

Widget _layer(
  CanvasDocument document,
  List<VoiceParticipant> participants,
  CanvasPresenceTileOverrides overrides,
  _Reports reports, {
  bool hideSelfCamera = false,
}) => CanvasPresenceLayer(
  document: document,
  participants: participants,
  cameraViewFor: _noView,
  screenShareViewFor: _noView,
  overrides: overrides,
  onCommit: (_, __) {},
  onVideoInterest: reports.call,
  hideSelfCamera: hideSelfCamera,
);

void main() {
  testWidgets('every tile on screen is reported as wanting video', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final reports = _Reports();

    await tester.pumpWidget(
      _wrap(
        _layer(
          document,
          const [_noor, _ada],
          CanvasPresenceTileOverrides(),
          reports,
        ),
      ),
    );
    await tester.pump();

    expect(reports.last, {
      'camera:user-noor',
      'camera:user-ada',
      'screen:user-ada',
    });
  });

  testWidgets('panning a tile past the exit band drops it from the interest '
      'set, and panning back puts it straight back', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final reports = _Reports();

    await tester.pumpWidget(
      _wrap(
        _layer(document, const [_noor], CanvasPresenceTileOverrides(), reports),
      ),
    );
    await tester.pump();
    expect(reports.last, {'camera:user-noor'});

    document.setCamera(document.camera.copyWith(x: 100000, y: 100000));
    await tester.pump();
    expect(
      reports.last,
      isEmpty,
      reason:
          'an empty set is a real answer: nothing on this canvas wants '
          'video, which is not the same as having no opinion',
    );
    expect(reports.last, isNotNull);

    document.setCamera(const Camera());
    await tester.pump();
    expect(reports.last, {'camera:user-noor'});
  });

  testWidgets('a nudge that never leaves the exit band reports nothing new', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final reports = _Reports();

    await tester.pumpWidget(
      _wrap(
        _layer(document, const [_noor], CanvasPresenceTileOverrides(), reports),
      ),
    );
    await tester.pump();
    final afterFirstPaint = reports.reported.length;

    // Twenty small pans, the shape of somebody dragging the canvas around.
    for (var i = 1; i <= 20; i++) {
      document.setCamera(document.camera.copyWith(x: i * 5.0));
      await tester.pump();
    }

    expect(
      reports.reported.length,
      afterFirstPaint,
      reason:
          'an unchanged set must not be re-reported, or every pan frame '
          'would churn the session',
    );
  });

  testWidgets('hiding a tile withdraws its video interest', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();
    final reports = _Reports();

    await tester.pumpWidget(
      _wrap(_layer(document, const [_noor, _ada], overrides, reports)),
    );
    await tester.pump();
    expect(reports.last, contains('screen:user-ada'));

    overrides.setHidden('screen:user-ada', true);
    await tester.pump();

    expect(reports.last, isNot(contains('screen:user-ada')));
    expect(reports.last, contains('camera:user-ada'));
  });

  testWidgets('a canvas with no call roster reports no opinion, never an '
      'empty set', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final reports = _Reports();

    await tester.pumpWidget(
      _wrap(_layer(document, const [], CanvasPresenceTileOverrides(), reports)),
    );
    await tester.pump();

    expect(
      reports.last,
      isNull,
      reason:
          'a canvas open with no call to speak for must not cull one '
          'running somewhere it knows nothing about',
    );
  });

  /// Not a tautology despite `presenceTileKeys` building through the shared
  /// `videoSubscriptionKey`: this is what fails if a third tile kind is ever
  /// added to the canvas without teaching the rtc package about it, which
  /// would mean an interest set naming a key no publication can ever match,
  /// and so a track culled while somebody is looking at it.
  test('every tile kind the canvas can name is one a cull can act on', () {
    final keys = presenceTileKeys(const [_noor, _ada]);
    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(
        cullableTrackKinds,
        contains(presenceTileKind(key)),
        reason: '$key names a kind the culler would refuse to act on',
      );
    }
  });

  testWidgets('unmounting hands the decision back at once', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final reports = _Reports();

    await tester.pumpWidget(
      _wrap(
        _layer(document, const [_noor], CanvasPresenceTileOverrides(), reports),
      ),
    );
    await tester.pump();
    expect(reports.last, isNotNull);

    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pump();

    expect(
      reports.last,
      isNull,
      reason:
          'a closed canvas must not leave a stale interest set culling a '
          'call it is no longer looking at',
    );
  });
}
