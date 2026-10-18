// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Geometry regression for the member profile popover: it used to reserve a
/// fixed 120px below the anchor and squeeze everything else into a scrolled,
/// clipped sliver instead of flipping above the row when there was no room
/// below - reported directly by the owner from a screenshot where "Remove
/// from Space..." and the row after it sat past the bottom of the window.
///
/// Each assertion reads the actual rendered `Rect` of the menu's own last
/// item, not just that the menu exists: `SingleChildScrollView` clips an
/// overflowing child without shrinking it, so a presence-only check would
/// have passed on the bug as readily as it passes on the fix.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

// Every moderation row on, so the popover is as tall as the screenshot's.
const _fullModeration =
    Perm.kickMembers | Perm.banMembers | Perm.manageRoles | Perm.administrator;

Widget _harness(Widget child, {api.UserProfile profile = _other}) =>
    ProviderScope(
      overrides: [
        myPermissionsProvider.overrideWithValue(_fullModeration),
        membersProvider.overrideWith((ref) async => [profile]),
        rolesProvider.overrideWith((ref) async => const <api.Role>[]),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

/// A small anchor row, positioned at [top], that opens the real popover
/// through [showMemberProfile] - the same call a member row's context menu
/// makes - so this exercises the production positioning code exactly.
Widget _anchorRow(double top, api.UserProfile profile) => Positioned(
  left: 20,
  top: top,
  child: SizedBox(
    width: 160,
    height: 40,
    child: Consumer(
      builder: (context, ref, _) => TextButton(
        onPressed: () => showMemberProfile(context, profile: profile),
        child: const Text('open'),
      ),
    ),
  ),
);

/// Opens the popover and returns the rect of [lastItemText] - the whole
/// (pushed) view's own last row, not just its top items, proof the whole
/// thing laid out. [enterModerate] pushes into Moderate first, for the tests
/// whose tallest content lives there.
Future<Rect> _openAt(
  WidgetTester tester, {
  required Size window,
  required double anchorTop,
  api.UserProfile profile = _other,
  bool enterModerate = true,
  String lastItemText = 'Password reset code...',
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    _harness(
      Stack(children: [_anchorRow(anchorTop, profile)]),
      profile: profile,
    ),
  );
  await tester.pump();

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  expect(find.byType(AppMenu), findsOneWidget);
  if (enterModerate) {
    await tester.tap(find.text('Moderate...'));
    await tester.pumpAndSettle();
  }
  return tester.getRect(find.text(lastItemText));
}

void main() {
  testWidgets(
    'a popover anchored low in the window flips above rather than running '
    'off the bottom',
    (tester) async {
      const window = Size(900, 700);
      final lastItem = await _openAt(tester, window: window, anchorTop: 640);

      expect(
        lastItem.bottom,
        lessThanOrEqualTo(window.height),
        reason:
            'the moderation section\'s last row should land inside the '
            'window; a fixed below-the-anchor reserve leaves it scrolled '
            'past the bottom edge instead',
      );
      expect(lastItem.top, greaterThanOrEqualTo(0));
    },
  );

  testWidgets(
    'a popover anchored high in a short window clamps rather than flipping '
    'off the top',
    (tester) async {
      const window = Size(900, 500);
      final lastItem = await _openAt(tester, window: window, anchorTop: 10);

      expect(
        lastItem.top,
        greaterThanOrEqualTo(0),
        reason:
            'a menu with nowhere below and not enough room above must clamp '
            'to the top edge, not slide past it',
      );
      expect(lastItem.bottom, lessThanOrEqualTo(window.height));
    },
  );
}
