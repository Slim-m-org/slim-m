// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';

Future<void> _pump(WidgetTester tester, double width) => tester.pumpWidget(
  MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: const ProfileFieldPair(
          first: SizedBox(key: Key('first'), height: 40),
          second: SizedBox(key: Key('second'), height: 40),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('sits side by side when there is room', (tester) async {
    await _pump(tester, 600);
    expect(
      tester.getTopLeft(find.byKey(const Key('second'))).dy,
      tester.getTopLeft(find.byKey(const Key('first'))).dy,
    );
  });

  testWidgets('stacks below the minimum pair width', (tester) async {
    await _pump(tester, ProfileFieldPair.kPairMinWidth - 1);
    expect(
      tester.getTopLeft(find.byKey(const Key('second'))).dy,
      greaterThan(tester.getBottomLeft(find.byKey(const Key('first'))).dy),
    );
  });
}
