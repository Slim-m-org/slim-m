// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// At 200% text the members pane title stays on one line and inside the pane
/// instead of wrapping with the count orphaned.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_header.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('MEMBERS and its count stay on one line at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        builder: (context, child) => MediaQuery(
          data: MediaQueryData.fromView(
            View.of(context),
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 150,
              child: MemberPaneHeader(
                count: 3,
                onInvite: () {},
                onStartSelecting: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final label = find.text('MEMBERS · 3');
    final text = tester.renderObject<RenderBox>(label);
    const style = AppText.label;
    expect(
      text.size.height,
      lessThanOrEqualTo(style.fontSize! * 2 * (style.height ?? 1.3) + 1),
    );
    expect(tester.getRect(label).right, lessThanOrEqualTo(150));
  });
}
