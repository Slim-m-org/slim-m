// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// AppContentColumn caps a settings list at 720 in an open window, and fills
/// a surface that already bounds its own width (a floating modal panel)
/// instead of centring a narrower column inside it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _probe = Key('probe');

Future<double> _widthIn(WidgetTester tester, {required bool bounded}) async {
  tester.view.physicalSize = const Size(860, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Widget column = const AppContentColumn(
    child: SizedBox(key: _probe, width: double.infinity, height: 10),
  );
  if (bounded) column = AppBoundedWidth(child: column);
  await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: column));
  return tester.getSize(find.byKey(_probe)).width;
}

void main() {
  testWidgets('an open window caps the column at kContentColumnMax',
      (tester) async {
    expect(await _widthIn(tester, bounded: false), kContentColumnMax);
  });

  testWidgets('a bounded surface lets the column fill it', (tester) async {
    expect(await _widthIn(tester, bounded: true), 860);
  });
}
