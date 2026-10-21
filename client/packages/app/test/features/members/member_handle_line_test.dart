// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The copy icon after a handle appears on hover, on focus and at touch density.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/member_handle_line.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, {bool touch = false}) =>
    tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: AppTouchTargets(
              enabled: touch,
              child: const MemberHandleLine(
                username: 'maya',
                extras: ['she/her'],
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      ),
    );

double _opacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.ancestor(
        of: find.byTooltip('Copy username'),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

void main() {
  testWidgets('hidden until hovered with a pointer', (tester) async {
    await _pump(tester);
    expect(_opacity(tester), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('@maya')));
    await tester.pump();
    expect(_opacity(tester), 1);

    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(_opacity(tester), 0);
  });

  testWidgets('always shown at touch density', (tester) async {
    await _pump(tester, touch: true);
    expect(_opacity(tester), 1);
  });
}
