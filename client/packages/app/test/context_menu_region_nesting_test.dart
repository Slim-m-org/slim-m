// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click inside a nested [ContextMenuRegion] opens only the innermost
/// menu.
///
/// The rail wraps its whole viewport in a region ("Create channel") and
/// every DM row carries one of its own. Opening on the *down* event meant
/// both fired - Flutter delivers every nested recognizer's down callback once
/// the press deadline passes, arena or not - and the owner saw the rail's
/// item drawn over the row's own. Only the up event is the arena winner's.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

/// A right-click the way a mouse makes one: pressed, held past
/// [kPressTimeout], released. `tapAt` releases instantly, which never reaches
/// the deadline path this file exists to cover.
Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a right-click on the inner region opens only its menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ContextMenuRegion(
            itemsBuilder: (context, close) => [
              AppMenuItem(label: 'Outer only', onTap: close),
            ],
            child: Center(
              child: ContextMenuRegion(
                itemsBuilder: (context, close) => [
                  AppMenuItem(label: 'Inner only', onTap: close),
                ],
                child: const SizedBox(
                  width: 200,
                  height: 48,
                  child: Text('row'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Held past kPressTimeout on purpose; that hold is the whole bug.
    await _rightClick(tester, tester.getCenter(find.text('row')));

    expect(find.text('Inner only'), findsOneWidget);
    expect(
      find.text('Outer only'),
      findsNothing,
      reason: 'the enclosing region must not open on top of the row\'s own',
    );
  });

  testWidgets('a right-click beside the inner region still opens the outer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ContextMenuRegion(
            itemsBuilder: (context, close) => [
              AppMenuItem(label: 'Outer only', onTap: close),
            ],
            // Painted, so it hit-tests; an empty box would swallow nothing.
            child: const ColoredBox(
              color: Colors.transparent,
              child: SizedBox.expand(),
            ),
          ),
        ),
      ),
    );

    await _rightClick(tester, const Offset(400, 300));

    expect(find.text('Outer only'), findsOneWidget);
  });
}
