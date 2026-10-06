// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone sheet keeps its content above the keyboard and scrolls it when it
/// does not fit, so a caller never repeats the inset-and-scroll block itself.
///
/// `showModalBottomSheet` reserves neither: every form sheet used to copy the
/// padding by hand, and the ones that forgot looked fine on desktop (no
/// keyboard) and in tests, then ran under the keyboard or overflowed on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const Size _phone = Size(390, 844);
const double _keyboard = 300;

Future<void> _openWithKeyboard(
  WidgetTester tester, {
  required Widget body,
  bool scrolls = false,
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: GestureDetector(
            onTap: () => showAppSheet<void>(
              context,
              scrolls: scrolls,
              builder: (_) => body,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the last row of a short sheet sits above the keyboard', (
    tester,
  ) async {
    await _openWithKeyboard(
      tester,
      body: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [TextField(), SizedBox(key: Key('last'), height: 40)],
      ),
    );

    final bottom = tester.getBottomLeft(find.byKey(const Key('last'))).dy;

    expect(bottom, lessThanOrEqualTo(_phone.height - _keyboard));
  });

  testWidgets(
      'a column taller than the space left scrolls rather than '
      'overflowing', (tester) async {
    await _openWithKeyboard(
      tester,
      body: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [TextField(), SizedBox(height: 900)],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('content that scrolls on its own is not wrapped again', (
    tester,
  ) async {
    await _openWithKeyboard(
      tester,
      scrolls: true,
      body: ListView(children: const [TextField(), SizedBox(height: 900)]),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsNothing);
  });
}
