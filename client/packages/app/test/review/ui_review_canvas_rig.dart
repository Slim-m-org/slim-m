// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mount every canvas review suite shares: the real [CanvasPane] over the canvas fake API, a pinned call, and a capture that names each PNG through [reviewName].
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart'
    show batchProfilesControllerProvider;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../features/canvas/canvas_pane_harness.dart';
import '../features/voice/voice_snapshot_fixtures.dart';
import '../support/fake_voice.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'review_support.dart';
import 'ui_review_canvas_board.dart';
import 'ui_review_canvas_call.dart';
import 'ui_review_canvas_photo.dart';

export 'ui_review_canvas_call.dart';

/// The two review viewports, by the name their PNGs carry.
const reviewCanvasViewports = <String, Size>{
  'phone': Size(390, 844),
  'desktop': Size(1280, 800),
};

class CanvasReviewRig {
  CanvasReviewRig._(
    this.tester,
    this.viewport,
    this.fixture,
    this.container,
    this.hasPhoto,
  );

  final WidgetTester tester;
  final String viewport;
  final CanvasPaneFixture fixture;
  final ProviderContainer container;
  final bool hasPhoto;
  String theme = 'dark';

  bool get desktop => viewport == 'desktop';
  Size get size => reviewCanvasViewports[viewport]!;
  CanvasEngine get engine =>
      container.read(canvasEngineProvider('c1').notifier);
  CanvasDocument get document => engine.document;
  FakeVoiceController get voice =>
      container.read(voiceControllerProvider.notifier) as FakeVoiceController;

  Widget _app() => UncontrolledProviderScope(
    container: container,
    child: RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(
          snapshotThemes[theme]!.brightness,
          snapshotThemes[theme]!.tokens,
        ),
        home: const Scaffold(body: CanvasPane(channelId: 'c1')),
      ),
    ),
  );

  Future<void> _settleFrames([int frames = 3]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 350));
    }
  }

  /// Gives the seeded photo its pixels once the pane has placed it; the fake attachment store only serves one transparent pixel.
  Future<void> paintPhoto() async {
    if (!hasPhoto || document.objectBounds(reviewImageId) == null) return;
    final image = await tester.runAsync(reviewPhoto);
    document.setImageBitmap(reviewImageId, image!);
  }

  bool _disposed = false;

  /// Frees the container once; the mount's teardown and [retire] may both call it.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
    await fixture.events.close();
  }

  /// Unmounts the pane and frees it, so a test can mount again for the next theme.
  Future<void> retire() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await dispose();
  }

  Future<void> setTheme(String next) async {
    theme = next;
    await tester.pumpWidget(_app());
    await _settleFrames(2);
    await paintPhoto();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Waits out whatever eases or fades after [act], then until the rendered text holds still.
  Future<void> settle() async {
    var last = renderedText(tester).join('|');
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final now = renderedText(tester).join('|');
      if (now == last && i > 2) return;
      last = now;
    }
  }

  /// Where the world point [world] sits on screen under the pane's current camera.
  Offset screenOf(Offset world) {
    final camera = document.camera;
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('canvas-surface')),
    );
    return origin +
        Offset(
          (world.dx - camera.x) * camera.zoom,
          (world.dy - camera.y) * camera.zoom,
        );
  }

  Offset centreOf(String objectId) {
    final b = document.objectBounds(objectId)!;
    return screenOf(Offset(b.x + b.w / 2, b.y + b.h / 2));
  }

  /// A point on the left edge of an object, where an unfilled shape is hit.
  Offset edgeOf(String objectId) {
    final b = document.objectBounds(objectId)!;
    return screenOf(Offset(b.x + 1, b.y + b.h / 2));
  }

  Future<void> rightClick(Offset at) async {
    await tester.tapAt(at, buttons: kSecondaryButton);
    await tester.pump();
    await settle();
  }

  Future<void> longPress(Offset at) async {
    await tester.longPressAt(at);
    await tester.pump();
    await settle();
  }

  Future<void> leftClick(Offset at) async {
    await tester.tapAt(at, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await settle();
  }

  /// Writes [surface] in every review theme from this one mount, or in just [themes].
  Future<void> capture(
    String surface, {
    String? state,
    List<String> themes = reviewThemes,
  }) async {
    for (final next in themes) {
      if (theme != next) await setTheme(next);
      await paintPhoto();
      await tester.pump(const Duration(milliseconds: 100));
      final name = reviewName(surface, state, viewport, next);
      await expectSettled(tester, name, allowNoText: true);
      await writeSnapshot(tester, name);
      expect(tester.takeException(), isNull);
    }
    // The first theme again, so the next action runs on the state it started from.
    if (themes.length > 1 && theme != themes.first) {
      await setTheme(themes.first);
    }
  }
}

/// Runs [drive] on a fresh mount per theme and captures each: for a sheet or dialog, whose route keeps the theme it was pushed under.
Future<void> captureEachTheme(
  WidgetTester tester,
  Future<CanvasReviewRig> Function(String theme) mount,
  Future<void> Function(CanvasReviewRig rig) drive,
  String surface, {
  String? state,
}) async {
  for (final theme in reviewThemes) {
    final rig = await mount(theme);
    await drive(rig);
    await rig.capture(surface, state: state, themes: [theme]);
    await rig.retire();
  }
}

/// Mounts a canvas pane at [viewport] over [objects], on a call when [call] is given.
Future<CanvasReviewRig> mountReviewCanvas(
  WidgetTester tester,
  String viewport, {
  List<Map<String, dynamic>> objects = const [],
  VoiceState? call,
  int viewportStatus = 200,
  int placeStatus = 201,
  bool hasMore = false,
  int? timedOutUntil,
  int permissions = 0,
  List<Override> overrides = const [],
  String theme = 'dark',
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  tester.view.physicalSize = reviewCanvasViewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture =
      CanvasPaneFixture(
          viewportStatus: viewportStatus,
          placeStatus: placeStatus,
          hasMore: hasMore,
          mePermissions: permissions,
        )
        ..objects = objects
        ..timedOutUntil = timedOutUntil;
  final container = fixture.container(
    extraOverrides: [
      if (call != null)
        voiceControllerProvider.overrideWith(
          (ref) => SnapshotVoiceController(ref, call),
        ),
      batchProfilesControllerProvider.overrideWith(SeededProfiles.new),
      membersProvider.overrideWith((ref) async => reviewProfiles),
      ...overrides,
    ],
  );
  container.read(canvasOpenProvider.notifier).state = 'c1';
  final rig = CanvasReviewRig._(
    tester,
    viewport,
    fixture,
    container,
    objects.any((o) => o['id'] == reviewImageId),
  )..theme = theme;
  addTearDown(rig.dispose);
  await tester.pumpWidget(rig._app());
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await rig.paintPhoto();
  await rig._settleFrames();
  return rig;
}
