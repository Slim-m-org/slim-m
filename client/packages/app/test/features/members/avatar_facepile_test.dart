// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared facepile: avatars overlap by one step, "+n" follows the last, and nothing is drawn for nobody.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_facepile.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _dot(String key) => SizedBox.square(
  key: ValueKey(key),
  dimension: AppAvatarSize.s20,
  child: const ColoredBox(color: Colors.red),
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  testWidgets('overlaps each avatar by a step and puts "+n" after the last', (
    tester,
  ) async {
    await _pump(
      tester,
      AvatarFacepile(avatars: [_dot('a'), _dot('b'), _dot('c')], more: 4),
    );

    const step = AppAvatarSize.s20 - AppSpacing.s4;
    final a = tester.getRect(find.byKey(const ValueKey('a')));
    final b = tester.getRect(find.byKey(const ValueKey('b')));
    final c = tester.getRect(find.byKey(const ValueKey('c')));
    expect(b.left - a.left, step);
    expect(c.left - b.left, step);
    expect(tester.getRect(find.text('+4')).left, c.right + AppSpacing.s4);
    expect(tester.getRect(find.text('+4')).height, lessThanOrEqualTo(c.height));
  });

  testWidgets('draws no "+n" for zero', (tester) async {
    await _pump(tester, AvatarFacepile(avatars: [_dot('a')]));
    expect(find.textContaining('+'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('a'))).width,
      AppAvatarSize.s20,
    );
  });
}
