// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real `CanvasPane` on a busy board with a full call, for the pane
/// benchmarks: the engine, ops controller, commit queue and presence layers
/// are all the shipped ones; only the network and the media session are fake.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice_canvas/benchmark/board_fixture.dart';
import '../test/features/canvas/canvas_pane_harness.dart';
import 'perf_voice.dart';
import '../test/support/fake_blocks.dart';

Future<void> loadProductFont() async {
  final file = File('../design_system/fonts/IBMPlexSans-Regular.ttf');
  if (!file.existsSync()) return;
  final loader = FontLoader('IBM Plex Sans')
    ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await loader.load();
}

class PaneRig {
  PaneRig(this.tester);

  final WidgetTester tester;
  late final CanvasPaneFixture fixture;
  late final ProviderContainer container;
  late final CanvasDocument doc;
  PerfVoice? voice;

  Offset get origin => tester.getTopLeft(find.byType(CanvasSurface));

  /// Screen position of a world point under the current camera.
  Offset screenOf(double wx, double wy) {
    final camera = doc.camera;
    return origin +
        Offset((wx - camera.x) * camera.zoom, (wy - camera.y) * camera.zoom);
  }

  Future<void> mount(BoardSpec spec, {int participants = 25}) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    tester.view
      ..physicalSize = const ui.Size(1600, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas);
    final call = callOf(participants);
    container = fixture.container(
      extraOverrides: [
        voiceControllerProvider.overrideWith((ref) {
          final controller = PerfVoice(ref, call);
          voice = controller;
          return controller;
        }),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(ref, const BlocksState()),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    doc = surfaceDocument(tester);
    boardInputs(spec).forEach(doc.applyPlaced);
    await tester.runAsync(() => attachBitmaps(doc, spec.images));
    doc.refresh();
    await frame();
    await frame();
  }

  /// The topmost box object whose centre is on bare canvas: under no call
  /// tile and no higher box, so a press there picks it up.
  String pickDraggable() {
    final tiles = [
      for (final e in find.byType(CanvasPresenceManipulableTile).evaluate())
        tester.getRect(find.byWidget(e.widget)).inflate(8),
    ];
    final order = [
      for (var i = 49; i >= 0; i--) 'image-$i',
      for (var i = 199; i >= 0; i--) 'note-$i',
    ];
    final above = <Rect>[];
    for (final id in order) {
      final b = doc.objectBounds(id);
      if (b == null) continue;
      final box = Rect.fromLTWH(b.x, b.y, b.w, b.h);
      final c = screenOf(b.x + b.w / 2, b.y + b.h / 2);
      final free =
          !tiles.any((t) => t.contains(c)) &&
          !above.any((r) => r.contains(Offset(b.x + b.w / 2, b.y + b.h / 2)));
      if (free && const Rect.fromLTWH(0, 0, 1600, 1000).contains(c)) return id;
      above.add(box);
    }
    throw StateError('every box object is covered');
  }

  /// Unmounts the pane and lets its timers run out, so the test ends clean.
  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  }

  Future<double> frame() async {
    final sw = Stopwatch()..start();
    await tester.pump(const Duration(milliseconds: 16));
    return sw.elapsedMicroseconds.toDouble();
  }

  Future<double> timed(Future<void> Function() action) async {
    final sw = Stopwatch()..start();
    await action();
    return sw.elapsedMicroseconds.toDouble();
  }

  Future<void> pressKey(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await frame();
  }

  void pinch(Offset focal, double scale) {
    tester.binding.handlePointerEvent(
      PointerScaleEvent(
        position: focal,
        scale: scale,
        kind: PointerDeviceKind.mouse,
        device: 7,
      ),
    );
  }

  Future<TestGesture> mouse(Offset at, {int buttons = kPrimaryButton}) =>
      tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: buttons);
}
