// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An online member on a phone and nothing else gets a phone glyph where the
/// dot would be, big enough to read and still clear of the initials.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester, {
  required AppPresence status,
  required bool mobileOnly,
  double size = AppAvatarSize.s36,
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
            ),
          ),
        ),
      ),
    );

final _phone = find.byIcon(AppIcons.presencePhone);

void main() {
  testWidgets('online on a phone draws the glyph in the online colour', (
    tester,
  ) async {
    await _pump(tester, status: AppPresence.online, mobileOnly: true);
    expect(_phone, findsOneWidget);
    expect(find.byType(AppStatusDot), findsNothing);
    final icon = tester.widget<Icon>(_phone);
    expect(icon.color, AppTokens.light.status.online);
    expect(
      icon.size,
      const AppAvatarGeometry(AppAvatarSize.s36, phone: true).markDiameter,
    );
  });

  testWidgets('desktop or web keeps the plain dot', (tester) async {
    await _pump(tester, status: AppPresence.online, mobileOnly: false);
    expect(_phone, findsNothing);
    expect(find.byType(AppStatusDot), findsOneWidget);
  });

  testWidgets('away and do-not-disturb keep the dot whose shape names them', (
    tester,
  ) async {
    for (final status in [AppPresence.away, AppPresence.dnd]) {
      await _pump(tester, status: status, mobileOnly: true);
      expect(_phone, findsNothing, reason: '$status');
      expect(find.byType(AppStatusDot), findsOneWidget, reason: '$status');
    }
  });

  testWidgets('offline and unknown never draw a phone', (tester) async {
    for (final status in [AppPresence.offline, AppPresence.unknown]) {
      await _pump(tester, status: status, mobileOnly: true);
      expect(_phone, findsNothing, reason: '$status');
    }
  });

  testWidgets('the glyph sits on the dot corner, wider than the 8px dot', (
    tester,
  ) async {
    await _pump(
      tester,
      status: AppPresence.online,
      mobileOnly: true,
      size: AppAvatarSize.s24,
    );
    final avatar = tester.getRect(find.byType(AppAvatar));
    final glyph = tester.getRect(_phone);
    expect(glyph.width, greaterThan(8));
    expect(glyph.center.dx, greaterThan(avatar.center.dx));
    expect(glyph.center.dy, greaterThan(avatar.center.dy));
  });

  test('the phone mark claims a larger halo, so initials keep clear of it', () {
    for (final size in [
      AppAvatarSize.s24,
      AppAvatarSize.s36,
      AppAvatarSize.s56,
    ]) {
      final dot = AppAvatarGeometry(size);
      final phone = AppAvatarGeometry(size, phone: true);
      expect(phone.markDiameter, greaterThan(dot.markDiameter));
      expect(
        phone.initialsBox(withDot: true).width,
        lessThanOrEqualTo(dot.initialsBox(withDot: true).width),
      );
    }
  });
}
