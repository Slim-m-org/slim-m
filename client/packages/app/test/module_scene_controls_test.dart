// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The buttons under a module scene: the ones this client names, the ones the
/// module names, and all of them still reachable on a phone.
///
/// Both cases here were real bugs, and both were found by a module rather than
/// by a test. `docs/modules/building-modules.md` promises `controls` is "a list
/// of button labels shown under the scene", and it was not: five names had
/// buttons and everything else silently rendered nothing, so `music-box`
/// shipped with a `tempo` control that did not exist and a `play` that ran the
/// animation loop instead of playing its tune. And the row they sat in was a
/// `Row`, which overflowed at phone width and clipped whatever came last -
/// which was the full-screen button, so on a phone there was no way into
/// full screen at all.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

ModuleScene _scene(List<String> controls) => parseModuleScene(
  jsonEncode({
    r'$slim': 'scene/1',
    'width': 100,
    'height': 100,
    'ops': [
      {'op': 'rect', 'x': 0, 'y': 0, 'w': 100, 'h': 100, 'fill': 'accent'},
    ],
    'controls': controls,
    'live': true,
  }),
)!;

/// Mounts a scene at [width], the way a message bubble constrains one.
Future<List<String>> _pump(
  WidgetTester tester,
  ModuleScene scene, {
  required double width,
  VoidCallback? onExpand,
}) async {
  final sent = <String>[];
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ModuleSceneView(
              initial: scene,
              runCommand: (input) async {
                sent.add(input);
                return api.RunModuleCommandResult(
                  ok: true,
                  output: '',
                  error: null,
                );
              },
              onExpand: onExpand,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return sent;
}

void main() {
  group('a control this client has no icon for', () {
    testWidgets('renders under its own name', (tester) async {
      await _pump(tester, _scene(['tempo', 'play tune']), width: 360);
      expect(find.text('tempo'), findsOneWidget);
      expect(
        find.text('play tune'),
        findsOneWidget,
        reason: 'a module may offer a verb this client has never heard of',
      );
    });

    testWidgets('sends its own name as the action', (tester) async {
      final scene = _scene(['tempo']);
      final sent = await _pump(tester, scene, width: 360);
      await tester.tap(find.text('tempo'));
      await tester.pump();
      expect(sent, hasLength(1));
      expect(
        jsonDecode(sent.single)['action'],
        'tempo',
        reason: 'the label is the action; nothing translates it',
      );
    });
  });

  group('the reserved names keep their behaviour', () {
    testWidgets('play drives the animation loop, not an action', (
      tester,
    ) async {
      final sent = await _pump(tester, _scene(['play']), width: 360);
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Play'));
      await tester.pump();
      expect(
        sent.where((s) => s.contains('"action":"play"')),
        isEmpty,
        reason:
            'play is the toggle; a module wanting an action names it '
            'something else',
      );
    });

    testWidgets('step sends its action', (tester) async {
      final sent = await _pump(tester, _scene(['step']), width: 360);
      await tester.tap(find.bySemanticsLabel('Step forward'));
      await tester.pump();
      expect(jsonDecode(sent.single)['action'], 'step');
    });
  });

  group('the full-screen button on a narrow scene', () {
    testWidgets('stays inside the scene at phone width', (tester) async {
      // Every reserved control plus expand: what used to overflow a Row.
      await _pump(
        tester,
        _scene(['play', 'step', 'random', 'clear', 'reset']),
        width: 300,
        onExpand: () {},
      );
      final expand = find.bySemanticsLabel('Open full screen');
      expect(expand, findsOneWidget);
      expect(
        tester.getRect(expand).right,
        lessThanOrEqualTo(300),
        reason:
            'clipped past the edge it cannot be tapped, which is what left '
            'a phone with no way into full screen',
      );
    });

    testWidgets('is still tappable there', (tester) async {
      var expanded = false;
      await _pump(
        tester,
        _scene(['play', 'step', 'random', 'clear', 'reset']),
        width: 300,
        onExpand: () => expanded = true,
      );
      await tester.tap(find.bySemanticsLabel('Open full screen'));
      await tester.pump();
      expect(expanded, isTrue);
    });
  });
}
