// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene's `sweep` motion (decision 0043): how it parses, what bounds it, and
/// that the clock behind it runs once, stops, and never outlives the viewer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_sweep.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_timeline.dart';
import 'package:slimm_design_system/design_system.dart';

ModuleScene _scene(String opsJson) => parseModuleScene(
  '{"\$slim":"scene/1","width":100,"height":100,"ops":[$opsJson]}',
)!;

String _rect(String sweep, {int x = 0}) =>
    '{"op":"rect","x":$x,"y":0,"w":10,"h":10,"sweep":$sweep}';

SceneSweep _sweepOf(ModuleScene scene, [int index = 0]) =>
    sweepOf(scene.ops[index])!;

void main() {
  group('parsing bounds every number', () {
    test('a duration over the timeline is cut to it', () {
      final sweep = _sweepOf(_scene(_rect('{"secs":3600}')));

      expect(sweep.secs, SceneSweep.maxTimelineSeconds);
    });

    test('delay and duration share the one timeline', () {
      final sweep = _sweepOf(_scene(_rect('{"secs":50,"delay":4}')));

      expect(sweep.delay, 4);
      expect(sweep.end, SceneSweep.maxTimelineSeconds);
    });

    test('a delay at or past the ceiling is clamped and never throws', () {
      for (final delay in ['9.8', '9.89', '9.9', '9.95', '10', '10.1', '1e9']) {
        final sweep = _sweepOf(_scene(_rect('{"delay":$delay,"secs":1}')));
        expect(sweep.delay, inInclusiveRange(0, SceneSweep.maxTimelineSeconds));
        expect(sweep.secs, greaterThanOrEqualTo(SceneSweep.minSeconds));
        expect(
          sweep.delay + sweep.secs,
          lessThanOrEqualTo(SceneSweep.maxTimelineSeconds + 1e-9),
        );
      }
    });

    test('a missing, zero or negative duration gets the minimum', () {
      for (final body in ['{}', '{"secs":0}', '{"secs":-3}']) {
        expect(_sweepOf(_scene(_rect(body))).secs, SceneSweep.minSeconds);
      }
    });

    test('a huge or non-finite delta is clamped or ignored', () {
      final sweep = _sweepOf(_scene(_rect('{"secs":1,"dx":1e999,"dy":1e9}')));

      expect(sweep.dx, 0, reason: 'infinity reads as absent');
      expect(sweep.dy, SceneSweep.maxDelta);
    });

    test('a sweep that is not an object is no sweep', () {
      expect(sweepOf(_scene(_rect('"fast"')).ops.single), isNull);
    });

    test('only the first eight animated ops keep their motion', () {
      final ops = [for (var i = 0; i < 12; i++) _rect('{"secs":1}', x: i)];
      final scene = _scene(ops.join(','));

      final animated = scene.ops.where((op) => sweepOf(op) != null);
      expect(scene.ops, hasLength(12), reason: 'the rest still draw');
      expect(animated, hasLength(SceneSweep.maxPerScene));
    });

    test('an op that cannot move ignores a sweep', () {
      final scene = _scene(
        '{"op":"cells","cols":1,"rows":1,"data":"0","palette":["accent"],'
        '"sweep":{"secs":1}}',
      );

      expect(sweepOf(scene.ops.single), isNull);
    });
  });

  group('applySweep', () {
    final scene = _scene(
      '{"op":"rect","x":10,"y":20,"w":30,"h":40,'
      '"sweep":{"secs":2,"delay":1,"dx":100,"dw":-30}}',
    );
    RectOp at(double seconds) =>
        applySweep(scene.ops.single, seconds) as RectOp;

    test('holds the declared geometry through the delay', () {
      expect(at(0).x, 10);
      expect(at(1).x, 10);
    });

    test('interpolates linearly, then holds at the end', () {
      expect(at(2).x, 60);
      expect(at(3).x, 110);
      expect(at(99).x, 110);
      expect(at(99).w, 0, reason: 'a size never goes negative');
    });

    test('the end state is what an unclocked painter draws', () {
      expect(at(double.infinity).x, 110);
    });
  });

  group('the clock', () {
    Widget host(ModuleScene scene, {bool disableAnimations = false}) =>
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: SceneTimeline(
              scene: scene,
              tokens: AppTokens.dark,
              images: const {},
              size: const Size(100, 100),
            ),
          ),
        );

    ModuleScenePainter painter(WidgetTester tester) =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(SceneTimeline),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as ModuleScenePainter;

    final moving = _scene(_rect('{"secs":2,"dx":50}'));

    testWidgets('runs from zero to the end once, then nothing is scheduled', (
      tester,
    ) async {
      await tester.pumpWidget(host(moving));
      expect(painter(tester).time!.value, 0);

      await tester.pump(const Duration(seconds: 1));
      expect(painter(tester).time!.value, closeTo(1, 0.01));

      await tester.pump(const Duration(seconds: 5));
      expect(painter(tester).time!.value, closeTo(2, 0.01));
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'a finished sweep must leave no ticker running',
      );
    });

    testWidgets('a still scene never starts a clock', (tester) async {
      await tester.pumpWidget(host(_scene('{"op":"rect","w":5,"h":5}')));

      expect(painter(tester).time, isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('a new frame restarts it, the same frame does not', (
      tester,
    ) async {
      await tester.pumpWidget(host(moving));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(host(moving));
      expect(painter(tester).time!.value, closeTo(1, 0.01));

      await tester.pumpWidget(host(_scene(_rect('{"secs":2,"dx":50}'))));
      expect(painter(tester).time!.value, 0);
    });

    testWidgets('reduced motion shows the end state with no clock', (
      tester,
    ) async {
      await tester.pumpWidget(host(moving, disableAnimations: true));

      expect(painter(tester).time, isNull);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('backgrounding the app stops it', (tester) async {
      await tester.pumpWidget(host(moving));
      await tester.pump(const Duration(milliseconds: 500));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(painter(tester).time, isNull);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 3));
      expect(painter(tester).time, isNull, reason: 'it does not replay');
    });

    testWidgets('a scene off screen has no ticker (TickerMode off)', (
      tester,
    ) async {
      await tester.pumpWidget(TickerMode(enabled: false, child: host(moving)));
      await tester.pump(const Duration(seconds: 5));

      expect(painter(tester).time!.value, 0, reason: 'muted, not advancing');
    });
  });
}
