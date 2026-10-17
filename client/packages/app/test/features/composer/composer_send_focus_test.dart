// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// After a send from the button under a web screen reader, the field gets a
/// fresh text input connection; anywhere else it just keeps focus.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_send_focus.dart';

void main() {
  late FocusNode focus;
  late TextEditingController controller;

  setUp(() {
    focus = FocusNode();
    controller = TextEditingController();
  });

  tearDown(() {
    focus.dispose();
    controller.dispose();
  });

  Future<BuildContext> pumpField(
    WidgetTester tester, {
    required bool screenReader,
  }) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(accessibleNavigation: screenReader),
          child: Material(
            child: Builder(
              builder: (c) {
                context = c;
                return TextField(controller: controller, focusNode: focus);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    return context;
  }

  List<String> connectionCalls(WidgetTester tester) => [
    for (final call in tester.testTextInput.log)
      if (call.method == 'TextInput.clearClient' ||
          call.method == 'TextInput.setClient')
        call.method,
  ];

  testWidgets('a web screen reader send reopens the input connection', (
    tester,
  ) async {
    final context = await pumpField(tester, screenReader: true);
    tester.testTextInput.log.clear();

    reattachFieldAfterButtonSend(context, focus, web: true);
    await tester.pump();
    await tester.pump();

    expect(focus.hasFocus, isTrue);
    expect(connectionCalls(tester), [
      'TextInput.clearClient',
      'TextInput.setClient',
    ]);
  });

  for (final (name, web, reader) in const [
    ('a web pointer send', true, false),
    ('a native screen reader send', false, true),
  ]) {
    testWidgets('$name keeps the connection it has', (tester) async {
      final context = await pumpField(tester, screenReader: reader);
      tester.testTextInput.log.clear();

      reattachFieldAfterButtonSend(context, focus, web: web);
      await tester.pump();
      await tester.pump();

      expect(focus.hasFocus, isTrue);
      expect(connectionCalls(tester), isEmpty);
    });
  }
}
