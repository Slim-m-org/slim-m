// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_entrance.dart';

Widget _shell(Key key) => MaterialApp(
  home: DesktopEntrance(
    key: key,
    child: const SizedBox.expand(child: Text('content')),
  ),
);

double _contentOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(DesktopEntrance),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

void main() {
  setUp(resetDesktopEntranceForTest);

  testWidgets('the first shell eases in, a remounted shell does not', (
    tester,
  ) async {
    await tester.pumpWidget(_shell(const ValueKey('first')));
    expect(_contentOpacity(tester), lessThan(1));
    await tester.pump(kDesktopEntranceDuration);

    // A Space switch mounts a whole new shell under a different key.
    await tester.pumpWidget(_shell(const ValueKey('second')));
    expect(_contentOpacity(tester), 1);
  });
}
