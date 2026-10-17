// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `input` scene op: how it parses, and how the field over the canvas
/// behaves when the module and the person typing disagree.
///
/// That disagreement is the whole design. The module owns the value, so a scene
/// can correct or clear what was typed - except while somebody has the field
/// focused, where overwriting under their cursor would feel like the app
/// fighting them. Both halves are pinned here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_inputs.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_design_system/design_system.dart';

ModuleScene _scene(String opsJson) => parseModuleScene(
  '{"\$slim":"scene/1","width":100,"height":100,"ops":[$opsJson]}',
)!;

InputOp? _inputOp(String opsJson) {
  final ops = _scene(opsJson).ops;
  return ops.length == 1 && ops.first is InputOp ? ops.first as InputOp : null;
}

Future<List<String>> _pumpOverlay(
  WidgetTester tester,
  ModuleScene scene, {
  List<String>? into,
}) async {
  final submitted = into ?? <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 200,
          child: SceneInputOverlay(
            scene: scene,
            size: const Size(200, 200),
            onSubmit: submitted.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return submitted;
}

void main() {
  group('parsing', () {
    test('a well-formed input op reaches the scene', () {
      final op = _inputOp(
        '{"op":"input","x":10,"y":20,"w":60,"submit":"guess",'
        '"value":"cat","placeholder":"your guess","max":12}',
      );

      expect(op, isNotNull);
      expect(op!.submit, 'guess');
      expect(op.value, 'cat');
      expect(op.placeholder, 'your guess');
      expect(op.maxLength, 12);
      expect(op.x, 10);
      expect(op.w, 60);
    });

    test('an op with no submit name is skipped: nothing could report it', () {
      expect(_scene('{"op":"input","x":0,"y":0,"w":50}').ops, isEmpty);
      expect(
        _scene('{"op":"input","x":0,"y":0,"w":50,"submit":""}').ops,
        isEmpty,
      );
    });

    test('max length is clamped, not trusted', () {
      expect(
        _inputOp(
          '{"op":"input","x":0,"y":0,"w":9,"submit":"a","max":99999}',
        )!.maxLength,
        InputOp.maxMaxLength,
        reason: 'the text rides back to the module on every submission',
      );
      expect(
        _inputOp(
          '{"op":"input","x":0,"y":0,"w":9,"submit":"a","max":0}',
        )!.maxLength,
        1,
      );
    });

    test('an absent max falls back to the default', () {
      expect(
        _inputOp('{"op":"input","x":0,"y":0,"w":9,"submit":"a"}')!.maxLength,
        InputOp.defaultMaxLength,
      );
    });

    test('an input op has no tap, so a tap never lands on one', () {
      final scene = _scene(
        '{"op":"input","x":0,"y":0,"w":100,"submit":"guess"}',
      );

      expect(
        sceneTapAction(scene, const Offset(50, 50), const Size(100, 100)),
        isNull,
      );
    });
  });

  group('the field over the canvas', () {
    testWidgets('a scene with no input op renders no field', (tester) async {
      await _pumpOverlay(
        tester,
        _scene('{"op":"rect","x":0,"y":0,"w":9,"h":9}'),
      );

      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('the module value seeds the field', (tester) async {
      await _pumpOverlay(
        tester,
        _scene(
          '{"op":"input","x":0,"y":0,"w":100,"submit":"g","value":"seed"}',
        ),
      );

      expect(find.text('seed'), findsOneWidget);
    });

    testWidgets('submitting reports the colon-separated action', (
      tester,
    ) async {
      final submitted = await _pumpOverlay(
        tester,
        _scene('{"op":"input","x":0,"y":0,"w":100,"submit":"guess"}'),
      );

      await tester.enterText(find.byType(TextField), '  otter  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(submitted, ['guess:otter'], reason: 'trimmed, and named');
    });

    testWidgets('the module can change the value between scenes', (
      tester,
    ) async {
      await _pumpOverlay(
        tester,
        _scene('{"op":"input","x":0,"y":0,"w":100,"submit":"g","value":"one"}'),
      );
      expect(find.text('one'), findsOneWidget);

      await _pumpOverlay(
        tester,
        _scene('{"op":"input","x":0,"y":0,"w":100,"submit":"g","value":"two"}'),
      );

      expect(find.text('two'), findsOneWidget, reason: 'the module owns it');
      expect(find.text('one'), findsNothing);
    });

    testWidgets('a scene that did not change the value leaves typing alone', (
      tester,
    ) async {
      const op =
          '{"op":"input","x":0,"y":0,"w":100,"submit":"g","value":"seed"}';
      await _pumpOverlay(tester, _scene(op));

      await tester.enterText(find.byType(TextField), 'half typed');
      await tester.pump();

      // The same scene arriving again - somebody else acted on a shared scene.
      await _pumpOverlay(tester, _scene(op));

      expect(
        find.text('half typed'),
        findsOneWidget,
        reason: 'an unchanged value must not reset the field under the cursor',
      );
    });

    testWidgets('two fields are independent', (tester) async {
      final submitted = await _pumpOverlay(
        tester,
        _scene(
          '{"op":"input","x":0,"y":0,"w":100,"submit":"first"},'
          '{"op":"input","x":0,"y":50,"w":100,"submit":"second"}',
        ),
      );

      expect(find.byType(TextField), findsNWidgets(2));
      await tester.enterText(find.byType(TextField).last, 'b');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(submitted, ['second:b']);
    });
  });
}
