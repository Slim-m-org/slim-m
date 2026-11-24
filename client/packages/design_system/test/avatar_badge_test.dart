// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A departed badge takes the presence dot's place: same geometry, no dot, and a glyph that says it without colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester, {
  AppAvatarBadge? badge,
  AppPresence? status,
  bool mobileOnly = false,
  double size = AppAvatarSize.s28,
}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Center(
            child: AppAvatar(
              name: 'Nadia',
              size: size,
              status: status,
              mobileOnly: mobileOnly,
              badge: badge,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the badge sits on the dot corner and replaces the dot', (
    tester,
  ) async {
    for (final badge in AppAvatarBadge.values) {
      await _pump(tester, badge: badge, status: AppPresence.online);
      const geometry = AppAvatarGeometry(AppAvatarSize.s28, badge: true);
      final avatar = tester.getRect(find.byType(AppAvatar));
      final glyph = tester.getRect(find.byIcon(badge.icon));
      expect(find.byType(AppStatusDot), findsNothing, reason: '$badge');
      expect(
        (glyph.center - (avatar.topLeft + geometry.dotCenter)).distance,
        lessThan(0.01),
        reason: '$badge',
      );
      expect(glyph.width, closeTo(geometry.markDiameter, 0.01));
    }
  });

  testWidgets('the badge beats the phone glyph and the presence word', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      badge: AppAvatarBadge.left,
      status: AppPresence.online,
      mobileOnly: true,
    );
    expect(find.byIcon(AppIcons.presencePhone), findsNothing);
    expect(
      tester.getSemantics(find.byType(AppAvatar)).label,
      'Nadia, left the Space',
    );
    handle.dispose();
  });

  testWidgets('the glyph is a secondary text colour and the shapes differ', (
    tester,
  ) async {
    await _pump(tester, badge: AppAvatarBadge.deleted);
    expect(
      tester.widget<Icon>(find.byIcon(AppIcons.presenceDeleted)).color,
      AppTokens.light.textSecondary,
    );
    expect(AppIcons.presenceLeft, isNot(AppIcons.presenceDeleted));
  });

  testWidgets('no badge keeps the dot', (tester) async {
    await _pump(tester, status: AppPresence.online);
    expect(find.byType(AppStatusDot), findsOneWidget);
  });

  test('a badge claims the phone-sized halo so initials keep clear', () {
    for (final size in [AppAvatarSize.s24, AppAvatarSize.s28]) {
      final dot = AppAvatarGeometry(size);
      final badge = AppAvatarGeometry(size, badge: true);
      expect(badge.markDiameter, dot.markDiameter + 4);
      expect(
        badge.initialsBox(withDot: true).width,
        lessThanOrEqualTo(dot.initialsBox(withDot: true).width),
      );
    }
  });
}
