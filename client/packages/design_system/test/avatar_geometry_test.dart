// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The initials stay whole at every avatar size: inside the picture's edge and
/// clear of the presence dot. The owner's phone showed "NA" cut off under the
/// dot on a DM row, so this measures where the text actually lands rather than
/// asserting the widgets exist.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _sizes = [
  AppAvatarSize.s16,
  AppAvatarSize.s20,
  AppAvatarSize.s24,
  AppAvatarSize.s28,
  AppAvatarSize.s32,
  AppAvatarSize.s36,
  AppAvatarSize.s44,
  AppAvatarSize.s56,
  AppAvatarSize.s72,
  AppAvatarSize.s96,
];

List<Offset> _corners(Rect r) => [
      r.topLeft,
      r.topRight,
      r.bottomLeft,
      r.bottomRight,
    ];

Future<Rect> _pumpAvatar(
  WidgetTester tester,
  double size, {
  AppPresence? status,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: AppAvatar(name: 'Nadia Achebe', size: size, status: status),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getRect(find.byType(AppAvatar));
}

void main() {
  for (final size in _sizes) {
    testWidgets('initials sit inside the ring at ${size}px', (tester) async {
      final avatar = await _pumpAvatar(tester, size);
      final text = tester.getRect(find.text('NA'));
      final reach = size / 2 - AppAvatarGeometry.ringWidth;
      for (final corner in _corners(text)) {
        expect(
          (corner - avatar.center).distance,
          lessThanOrEqualTo(reach + 0.01),
          reason: 'a corner of the initials crosses the ring at ${size}px',
        );
      }
    });

    for (final status in [AppPresence.online, AppPresence.hidden]) {
      testWidgets('initials clear the $status dot at ${size}px', (
        tester,
      ) async {
        final avatar = await _pumpAvatar(tester, size, status: status);
        final text = tester.getRect(find.text('NA'));
        final dot = tester.getRect(find.byType(AppStatusDot));
        final halo = AppAvatarGeometry(size).dotHaloRadius;
        for (final corner in _corners(text)) {
          expect(
            (corner - dot.center).distance,
            greaterThanOrEqualTo(halo),
            reason: 'the dot covers the initials at ${size}px',
          );
          expect(
            (corner - avatar.center).distance,
            lessThanOrEqualTo(size / 2 - AppAvatarGeometry.ringWidth + 0.01),
          );
        }
      });
    }

    testWidgets('the dot is attached to the picture at ${size}px', (
      tester,
    ) async {
      final avatar = await _pumpAvatar(
        tester,
        size,
        status: AppPresence.online,
      );
      final dot = tester.getRect(find.byType(AppStatusDot));
      final toDot = (dot.center - avatar.center).distance;
      expect(toDot, greaterThan(size / 2 - dot.width / 2));
      expect(toDot, lessThan(size / 2 + dot.width));
      expect(dot.center.dx, greaterThan(avatar.center.dx));
      expect(dot.center.dy, greaterThan(avatar.center.dy));
    });
  }

  testWidgets('an unknown presence draws no dot and leaves the initials whole',
      (
    tester,
  ) async {
    final avatar = await _pumpAvatar(
      tester,
      AppAvatarSize.s24,
      status: AppPresence.unknown,
    );
    expect(find.byType(AppStatusDot), findsNothing);
    final withoutDot = tester.getRect(find.text('NA'));
    final reference = await _pumpAvatar(tester, AppAvatarSize.s24);
    expect(tester.getRect(find.text('NA')), withoutDot);
    expect(reference, avatar);
  });

  test('the same size gives the same geometry every time', () {
    for (final size in _sizes) {
      expect(
        AppAvatarGeometry(size).initialsBox(withDot: true),
        AppAvatarGeometry(size).initialsBox(withDot: true),
      );
      final box = AppAvatarGeometry(size).initialsBox(withDot: true);
      final plain = AppAvatarGeometry(size).initialsBox(withDot: false);
      expect(box.width, lessThanOrEqualTo(plain.width));
      expect(math.min(box.width, box.height), greaterThan(0));
    }
  });

  test('a dot-bearing size never falls below the dot minimum', () {
    for (final size in _sizes) {
      expect(AppAvatarGeometry(size).dotDiameter, greaterThanOrEqualTo(8));
    }
  });
}
