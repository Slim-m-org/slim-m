// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shared scene update reaches a viewer whatever its `state` says: `state` is
/// optional, so a module with nothing to remember (a roller, a clock) sends new
/// ops under the same - often absent - state, and that is still a new frame.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

String _frame(
  String status, {
  String? state,
  bool notes = false,
  bool live = false,
}) => jsonEncode({
  r'$slim': 'scene/1',
  'width': 100,
  'height': 100,
  'ops': [
    {'op': 'rect', 'x': 0, 'y': 0, 'w': 100, 'h': 100, 'fill': 'accent'},
    if (notes)
      {
        'op': 'notes',
        'notes': [
          {'f': 440.0, 't': 0.0, 'd': 0.1},
        ],
      },
  ],
  'controls': ['roll', if (live) 'play'],
  'live': live,
  'status': status,
  'state': ?state,
});

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.initial,
    required this.answer,
    this.onNotes,
  });

  final String initial;
  final String answer;
  final void Function(List<SceneNote>)? onNotes;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String shared = widget.initial;

  /// A broadcast frame: what every other client's message row is rebuilt with.
  void arrives(String next) => setState(() => shared = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 360,
          child: ModuleSceneView(
            initial: parseModuleScene(shared)!,
            onNotes: widget.onNotes,
            runCommand: (_) async =>
                api.RunModuleCommandResult(ok: true, output: widget.answer),
          ),
        ),
      ),
    ),
  );
}

Future<_HostState> _mount(
  WidgetTester tester,
  String initial, {
  String answer = '',
  void Function(List<SceneNote>)? onNotes,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    _Host(key: key, initial: initial, answer: answer, onNotes: onNotes),
  );
  await tester.pump();
  return key.currentState!;
}

void main() {
  testWidgets('a new frame with no state at all replaces the one on screen', (
    tester,
  ) async {
    final host = await _mount(tester, _frame('rolled 3'));
    expect(find.text('rolled 3'), findsOneWidget);

    host.arrives(_frame('rolled 5'));
    await tester.pump();

    expect(find.text('rolled 5'), findsOneWidget);
    expect(find.text('rolled 3'), findsNothing);
  });

  testWidgets(
    'a new frame under an unchanged state replaces the one on screen',
    (tester) async {
      final host = await _mount(tester, _frame('seven', state: 's'));

      host.arrives(_frame('eight', state: 's'));
      await tester.pump();

      expect(find.text('eight'), findsOneWidget);
    },
  );

  testWidgets('the same frame arriving again, re-parsed, changes nothing', (
    tester,
  ) async {
    final host = await _mount(
      tester,
      _frame('first', state: 's0'),
      answer: _frame('mine', state: 's1'),
    );
    await tester.tap(find.text('roll'));
    await pumpFrames(tester);
    expect(find.text('mine'), findsOneWidget);

    host.arrives(_frame('first', state: 's0'));
    await tester.pump();

    expect(find.text('mine'), findsOneWidget, reason: 'a rebuild is not news');
  });

  testWidgets('a stateless update from elsewhere never plays its sound', (
    tester,
  ) async {
    final played = <List<SceneNote>>[];
    final host = await _mount(tester, _frame('quiet'), onNotes: played.add);

    host.arrives(_frame('loud', notes: true));
    await tester.pump();

    expect(find.text('loud'), findsOneWidget);
    expect(played, isEmpty);
  });

  testWidgets(
    'this viewer\'s own stateless reply, echoed back, is not a reset',
    (tester) async {
      final host = await _mount(
        tester,
        _frame('before'),
        answer: _frame('after'),
      );
      await tester.tap(find.text('roll'));
      await pumpFrames(tester);
      expect(find.text('after'), findsOneWidget);

      host.arrives(_frame('after'));
      await tester.pump();

      expect(find.text('after'), findsOneWidget);
    },
  );
  testWidgets('a frame already on screen does not stop a playing board', (
    tester,
  ) async {
    final host = await _mount(
      tester,
      _frame('start', live: true),
      answer: _frame('tick', live: true),
    );
    await tester.tap(find.bySemanticsLabel('Play'));
    await pumpFrames(tester, frames: 12);
    expect(find.text('tick'), findsOneWidget);
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);

    host.arrives(_frame('tick', live: true));
    await tester.pump();

    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Pause'));
    await pumpFrames(tester, frames: 2);
  });
}
