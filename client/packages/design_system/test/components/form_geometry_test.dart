// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Geometry of AppInput: the box is the layout edge and the focus ring is drawn outside it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host(Widget child, {double width = 390}) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

void main() {
  group('AppInput edges', () {
    testWidgets(
        'the field box, its label, helper text and a button share a left and right edge',
        (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Label'),
              AppInput(helperText: 'Helper', placeholder: 'x'),
              AppInput(errorText: 'Broken', invalid: true),
              SizedBox(height: 40, child: ColoredBox(color: Colors.red)),
            ],
          ),
        ),
      );
      final button = tester.getRect(find.byType(ColoredBox).last);
      final label = tester.getTopLeft(find.text('Label'));
      for (final box in find.byType(Container).evaluate()) {
        final r = tester.getRect(find.byWidget(box.widget));
        if (r.height < 30) continue;
        expect(r.left, closeTo(label.dx, 0.5));
        expect(r.right, closeTo(button.right, 0.5));
      }
      expect(tester.getTopLeft(find.text('Helper')).dx, closeTo(label.dx, 0.5));
      expect(tester.getTopLeft(find.text('Broken')).dx, closeTo(label.dx, 0.5));
    });

    testWidgets('focusing paints a ring without moving the box',
        (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(_host(AppInput(focusNode: node)));
      final before = tester.getRect(find.byType(AppInput));
      node.requestFocus();
      await tester.pump();
      expect(tester.getRect(find.byType(AppInput)), before);
      final ring = find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null &&
            (w.decoration as BoxDecoration).color == null &&
            (w.decoration as BoxDecoration).borderRadius != null &&
            ((w.decoration as BoxDecoration).border! as Border).top.width == 2,
      );
      expect(ring, findsOneWidget);
      final r = tester.getRect(ring);
      expect(r.left, closeTo(before.left - 4, 0.5));
      expect(r.right, closeTo(before.right + 4, 0.5));
    });
  });
}
