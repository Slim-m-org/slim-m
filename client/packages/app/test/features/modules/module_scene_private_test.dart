// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A private scene is one viewer's own frame: the shared frames other people's moves produce must
/// not pull it off their screen, and closing it brings the shared frame back.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _frame(String status, String state, {bool isPrivate = false}) =>
    jsonEncode({
      r'$slim': 'scene/1',
      'width': 100,
      'height': 100,
      'ops': [
        {'op': 'rect', 'x': 0, 'y': 0, 'w': 100, 'h': 100, 'fill': 'accent'},
      ],
      'controls': isPrivate ? ['close'] : ['my board'],
      'status': status,
      'state': state,
      if (isPrivate) 'private': true,
    });

class _Host extends StatefulWidget {
  const _Host({required this.initial, required this.answers});

  final ModuleScene initial;
  final Map<String, String> answers;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late ModuleScene shared = widget.initial;

  void arrives(ModuleScene next) => setState(() => shared = next);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: ModuleSceneView(
              initial: shared,
              runCommand: (input) async {
                final action = jsonDecode(input)['action'] as String;
                return api.RunModuleCommandResult(
                  ok: true,
                  output: widget.answers[action],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

Future<_HostState> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _Host(
      initial: parseModuleScene(_frame('shared one', 'a'))!,
      answers: {
        'my board': _frame('my own board', 'mine', isPrivate: true),
        'close': _frame('shared again', 'b'),
      },
    ),
  );
  await tester.pump();
  return tester.state<_HostState>(find.byType(_Host));
}

void main() {
  test('only a scene that says private: true is private', () {
    expect(
      parseModuleScene(_frame('x', 's', isPrivate: true))!.isPrivate,
      isTrue,
    );
    expect(parseModuleScene(_frame('x', 's'))!.isPrivate, isFalse);
    final falsy = jsonDecode(_frame('x', 's'))..['private'] = false;
    expect(parseModuleScene(jsonEncode(falsy))!.isPrivate, isFalse);
    final text = jsonDecode(_frame('x', 's'))..['private'] = 'true';
    expect(parseModuleScene(jsonEncode(text))!.isPrivate, isFalse);
  });

  testWidgets(
    'a private frame replaces the shared one for the viewer who pressed',
    (tester) async {
      await _mount(tester);
      expect(find.text('shared one'), findsOneWidget);
      await tester.tap(find.text('my board'));
      await tester.pumpAndSettle();
      expect(find.text('my own board'), findsOneWidget);
      expect(find.text('shared one'), findsNothing);
    },
  );

  testWidgets(
    'a shared frame from someone else does not take a private board away',
    (tester) async {
      final host = await _mount(tester);
      await tester.tap(find.text('my board'));
      await tester.pumpAndSettle();
      host.arrives(parseModuleScene(_frame('someone else moved', 'c'))!);
      await tester.pumpAndSettle();
      expect(find.text('my own board'), findsOneWidget);
      expect(find.text('someone else moved'), findsNothing);
    },
  );

  testWidgets(
    'closing the private board brings the shared one back, and shared frames flow again',
    (tester) async {
      final host = await _mount(tester);
      await tester.tap(find.text('my board'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();
      expect(find.text('shared again'), findsOneWidget);
      host.arrives(parseModuleScene(_frame('someone else moved', 'd'))!);
      await tester.pumpAndSettle();
      expect(find.text('someone else moved'), findsOneWidget);
    },
  );
}
