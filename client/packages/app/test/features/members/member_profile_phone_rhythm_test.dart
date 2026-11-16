// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone sheet stacks name, handle, status, join date and About at the
/// popover's gaps; the copy, status and About buttons keep a 44pt finger reach
/// without growing their lines.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_identity.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../touch_hit_support.dart';

const _nov2026 = 1793750400000;

const _profile = api.UserProfile(
  id: 'user-test',
  username: 'testuser123',
  displayName: 'Tester',
  createdAt: _nov2026,
  statusText: 'heads down until 3',
);

/// Your own card, with nothing typed yet.
const _bare = api.UserProfile(
  id: 'user-test',
  username: 'testuser123',
  displayName: 'Tester',
  createdAt: _nov2026,
);

const _me = api.Me(
  id: 'user-test',
  username: 'testuser123',
  displayName: 'Tester',
  createdAt: _nov2026,
  permissions: 0,
);

Future<void> _pump(
  WidgetTester tester, {
  required bool phone,
  bool self = false,
}) async {
  final profile = self ? _bare : _profile;
  tester.view.physicalSize = Size(phone ? 390 : 800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        membersProvider.overrideWith((ref) async => [profile]),
        presenceForProvider.overrideWith((ref, id) => AppPresence.online),
        if (self) meProvider.overrideWith((ref) async => _me),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MemberProfileBody(
              profile: profile,
              compact: phone,
              profileOnly: true,
              onDone: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// The distance from each line's top to the next, name first.
List<double> _pitches(WidgetTester tester, String status) {
  final tops = [
    for (final label in ['Tester', '@testuser123', status, 'Joined Nov 2026'])
      tester.getTopLeft(find.text(label)).dy,
  ];
  return [for (var i = 1; i < tops.length; i++) tops[i] - tops[i - 1]];
}

void main() {
  for (final self in [false, true]) {
    final status = self ? 'Set a status' : 'heads down until 3';
    final card = self ? 'your own card' : "someone else's card";

    testWidgets('$card: the phone keeps the popover line pitch', (
      tester,
    ) async {
      await _pump(tester, phone: false, self: self);
      final popover = _pitches(tester, status);
      await _pump(tester, phone: true, self: self);
      final phone = _pitches(tester, status);

      expect(phone, popover);
    });
  }

  testWidgets('a finger copies the handle from its line, or from the name '
      'above it up to 44pt from its foot', (tester) async {
    final copied = _recordClipboard(tester);
    await _pump(tester, phone: true);
    final handle = tester.getRect(find.text('@testuser123'));

    await tester.tapAt(handle.center);
    await tester.pump();
    // 2pt inside the reach, which rises from the line's foot over the name.
    await tester.tapAt(Offset(handle.left + 2, handle.bottom - 41));
    await tester.pump();

    expect(copied, ['@testuser123', '@testuser123']);
  });

  testWidgets('on your own card the status line reaches 44pt down over the '
      'join date, and the handle keeps its own line', (tester) async {
    final copied = _recordClipboard(tester);
    await _pump(tester, phone: true, self: true);
    final handle = tester.getRect(find.text('@testuser123'));
    final status = tester.getRect(find.text('Set a status'));

    await tester.tapAt(Offset(handle.left + 2, handle.bottom - 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(copied, ['@testuser123']);
    expect(find.text('Appear offline'), findsNothing);

    // 2pt inside the reach, which falls from the line's top gap over the join date.
    await tester.tapAt(Offset(status.left + 2, status.top + 40));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Appear offline'), findsOneWidget);
  });

  testWidgets('your own About block is as tall on the phone as in the '
      'popover, its pencil still a 44pt target', (tester) async {
    double aboutHeight() =>
        tester.getSize(find.byKey(memberProfileAboutKey)).height;
    await _pump(tester, phone: false, self: true);
    final popover = aboutHeight();
    await _pump(tester, phone: true, self: true);

    expect(aboutHeight(), popover);
    expectTouchTarget(tester, find.byTooltip('Edit about'));
  });
}

/// What the card puts on the clipboard, in order.
List<String?> _recordClipboard(WidgetTester tester) {
  final copied = <String?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String?);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}
