// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A toolbar unmounted under the pointer fires no exit, so the row must not
/// stay hovered after it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_toolbar_anchor.dart';
import 'package:slimm_app/src/widgets/hover_reveal.dart';

void main() {
  testWidgets('removing the toolbar under the pointer un-hovers the row', (
    tester,
  ) async {
    final editing = ValueNotifier(false);
    var hovered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: editing,
              builder: (context, isEditing, _) => HoverReveal(
                builder: (context, h, menuOpen, focusWithin) {
                  hovered = h;
                  return MessageToolbarAnchor(
                    show: h && !isEditing,
                    toolbar: const SizedBox(
                      key: ValueKey('toolbar'),
                      width: 80,
                      height: 24,
                    ),
                    child: SizedBox(
                      key: const ValueKey('row'),
                      width: isEditing ? 0 : 300,
                      height: isEditing ? 0 : 60,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('row'))));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('toolbar'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar')), findsOneWidget);
    expect(hovered, isTrue);

    editing.value = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar')), findsNothing);
    expect(hovered, isFalse);
  });
}
