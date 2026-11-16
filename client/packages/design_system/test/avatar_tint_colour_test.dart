// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A person's own colour reaches their initials disc as a deep shade the white
/// initials read on, and a square avatar ignores it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _samples = [
  ...AppCanvasColors.cursors,
  Color(0xFFF2F2F2),
  Color(0xFF111111),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFFFFFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFF0000FF),
];

Widget _app(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Center(child: child),
    );

Color _discOf(WidgetTester tester) =>
    tester.widget<AppShapedDisc>(find.byType(AppShapedDisc)).color;

void main() {
  test('the initials read on every shade at better than AA', () {
    for (final colour in _samples) {
      final disc = avatarTintFromColour(colour);
      expect(
        contrastRatio(avatarTintInk, disc),
        greaterThanOrEqualTo(4.5),
        reason: '$colour -> $disc',
      );
    }
  });

  test('the shade keeps the hue and mutes it', () {
    for (final colour in AppCanvasColors.cursors) {
      final from = HSLColor.fromColor(colour);
      final disc = HSLColor.fromColor(avatarTintFromColour(colour));
      expect((disc.hue - from.hue).abs(), lessThan(2), reason: '$colour');
      expect(disc.saturation, lessThanOrEqualTo(0.46), reason: '$colour');
      expect(disc.lightness, inInclusiveRange(0.3, 0.4), reason: '$colour');
    }
  });

  test('every preset gets its own disc', () {
    final discs = AppCanvasColors.cursors.map(avatarTintFromColour).toSet();
    expect(discs, hasLength(AppCanvasColors.cursors.length));
  });

  testWidgets('tintColor draws the shade in place of the id hash', (
    tester,
  ) async {
    const colour = Color(0xFF3FA9C9);
    await tester.pumpWidget(
      _app(const AppAvatar(name: 'Tester', tintKey: 'u-1', tintColor: colour)),
    );

    expect(_discOf(tester), avatarTintFromColour(colour));
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('without tintColor the disc is the id hash, as before', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const AppAvatar(name: 'Ada', tintKey: 'u-1')));

    expect(_discOf(tester), avatarTintFor('u-1'));
  });

  testWidgets('a square avatar ignores tintColor', (tester) async {
    await tester.pumpWidget(
      _app(
        const AppAvatar(
          name: 'Build Bot',
          shape: AppAvatarShape.square,
          tintColor: Color(0xFF3FA9C9),
        ),
      ),
    );

    expect(find.byType(AppShapedDisc), findsNothing);
  });
}
