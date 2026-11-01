// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scrolling back through a conversation puts the keyboard away.
///
/// From the backlog: "if I scroll up away from the most recent messages it
/// might be nice for the keyboard to close to give me more reading room". On a
/// phone the keyboard is holding half the room somebody just went looking
/// through.
///
/// The distinction that carries the feature is *whose* scroll it was. A
/// transcript scrolls itself constantly - a new message arrives, a jump lands
/// on a search result - and closing the composer under someone mid-sentence
/// because a message arrived would be worse than never closing it at all. Only
/// a scroll carrying `dragDetails` is a person's own drag.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/dismiss_keyboard_on_drag.dart';
import 'package:slimm_design_system/design_system.dart';

/// The pane's own arrangement in miniature: a focus node standing in for the
/// composer, above a scrollable standing in for the transcript, under the real
/// [DismissKeyboardOnDrag] the pane wraps them in.
///
/// The production widget, not a copy of its logic: reproducing the listener
/// here would have passed no matter what the pane later did, which is the one
/// thing this test exists to prevent.
///
/// A bare [Focus] rather than a real [TextField]: a focused field runs a
/// blinking-cursor timer that keeps scheduling frames, so a `pumpAndSettle`
/// in reach of one never returns. Nothing here is about text entry - the
/// whole question is whether the node still holds focus.
Widget _harness({
  required FocusNode node,
  required ScrollController controller,
}) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: Column(
      children: [
        Expanded(
          child: DismissKeyboardOnDrag(
            child: ListView.builder(
              controller: controller,
              reverse: true,
              itemCount: 60,
              itemBuilder: (context, i) =>
                  SizedBox(height: 48, child: Text('message $i')),
            ),
          ),
        ),
        Focus(focusNode: node, child: const SizedBox(height: 48, width: 200)),
      ],
    ),
  ),
);

void main() {
  testWidgets('a deliberate drag closes the keyboard', (tester) async {
    final node = FocusNode();
    final controller = ScrollController();
    addTearDown(node.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(node: node, controller: controller));
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(node.hasFocus, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(
      node.hasFocus,
      isFalse,
      reason: 'scrolling back through the conversation gives the room over',
    );
  });

  testWidgets('the transcript scrolling itself does not', (tester) async {
    final node = FocusNode();
    final controller = ScrollController();
    addTearDown(node.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(node: node, controller: controller));
    node.requestFocus();
    await tester.pumpAndSettle();

    // A self-started scroll's notification, dispatched directly: a real one leaves the test waiting on scroll machinery.
    final ctx = tester.element(find.byType(ListView));
    ScrollStartNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 300,
        viewportDimension: 500,
        axisDirection: AxisDirection.up,
        devicePixelRatio: 1,
      ),
      context: ctx,
    ).dispatch(ctx);
    await tester.pump();

    expect(
      node.hasFocus,
      isTrue,
      reason: 'a message arriving must not close a composer being typed into',
    );
  });
}
