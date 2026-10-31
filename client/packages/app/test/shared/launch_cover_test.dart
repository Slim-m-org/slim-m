// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/launch_cover.dart';

Widget _cover({required bool covered, bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: LaunchCover(
    covered: covered,
    cover: const ColoredBox(
      color: Colors.black,
      child: Text('splash', textDirection: TextDirection.ltr),
    ),
    child: const Text('home', textDirection: TextDirection.ltr),
  ),
);

void main() {
  testWidgets('the cover takes taps while up and none while it fades', (
    tester,
  ) async {
    await tester.pumpWidget(_cover(covered: true));
    expect(find.text('home'), findsOneWidget, reason: 'built beneath');
    expect(find.text('splash'), findsOneWidget);
    expect(
      tester.widget<IgnorePointer>(find.byType(IgnorePointer).first).ignoring,
      isFalse,
    );

    await tester.pumpWidget(_cover(covered: false));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('splash'), findsOneWidget, reason: 'mid fade');
    expect(
      tester.widget<IgnorePointer>(find.byType(IgnorePointer).first).ignoring,
      isTrue,
    );

    await tester.pumpAndSettle();
    expect(find.text('splash'), findsNothing);
  });

  testWidgets('reduced motion drops the cover at once', (tester) async {
    await tester.pumpWidget(_cover(covered: true, reduced: true));
    await tester.pumpWidget(_cover(covered: false, reduced: true));
    expect(find.text('splash'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
