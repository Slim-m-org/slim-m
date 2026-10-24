// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a narrow member row the real role chip keeps its full size; module
/// badges are what shrink or drop.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/module_badges.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

api.UserProfile _member(String role) => api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
  roleIds: const ['r-admin'],
  roles: [role],
);

api.ModuleBadge _badge(String text, [String tone = 'normal']) =>
    api.ModuleBadge(
      moduleId: 'xp',
      name: 'level',
      item: api.ModuleSlotItem.parse({
        'nodes': [
          {'type': 'badge', 'text': text, 'tone': tone},
        ],
      }),
    );

class _Badges extends ModuleBadgesController {
  _Badges(super.ref, List<api.ModuleBadge> badges) {
    state = {'ada': badges};
  }

  @override
  void request(String id) {}
}

Future<void> _pump(
  WidgetTester tester,
  double width,
  List<api.ModuleBadge> badges, {
  String role = 'Mod',
}) async {
  // A fresh scope each time: an override change keeps the old notifier.
  await tester.pumpWidget(const SizedBox.shrink());
  tester.view.physicalSize = Size(width, 200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        liveEventsProvider.overrideWithValue(
          const Stream<api.ServerEvent>.empty(),
        ),
        moduleBadgesProvider.overrideWith((ref) => _Badges(ref, badges)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MemberRow(profile: _member(role), isSelf: false),
            ),
          ),
        ),
      ),
    ),
  );
}

Size _role(WidgetTester tester) => tester.getSize(
  find.byWidgetPredicate(
    (w) => w is AppBadge && w.variant == AppBadgeVariant.role,
  ),
);

void main() {
  testWidgets('a long role chip is not squeezed by module badges', (
    tester,
  ) async {
    await _pump(tester, 236, const [], role: 'Administrator');
    final alone = _role(tester);
    await _pump(tester, 236, [
      _badge('Streak 4'),
      _badge('LV 12'),
    ], role: 'Administrator');

    expect(_role(tester), alone);
  });

  final two = [_badge('Veteran of the season'), _badge('Streak 4', 'accent')];

  testWidgets('the role chip is the same size with and without module badges', (
    tester,
  ) async {
    await _pump(tester, 236, const []);
    final alone = _role(tester);
    await _pump(tester, 236, two);

    expect(_role(tester), alone);
    expect(find.byType(AppBadge), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('module badges truncate before the role chip does', (
    tester,
  ) async {
    await _pump(tester, 390, const []);
    final alone = _role(tester);
    await _pump(tester, 390, two);

    final moduleBadges = tester
        .widgetList<AppBadge>(find.byType(AppBadge))
        .where((b) => b.variant != AppBadgeVariant.role);
    expect(moduleBadges, isNotEmpty);
    expect(find.text('Veteran of the season'), findsOneWidget);
    final width = tester.getSize(find.text('Veteran of the season')).width;
    final natural = (TextPainter(
      text: TextSpan(
        text: 'Veteran of the season',
        style: tester.widget<Text>(find.text('Veteran of the season')).style,
      ),
      textDirection: TextDirection.ltr,
    )..layout()).width;
    expect(width, lessThan(natural));
    expect(_role(tester).width, alone.width);
  });

  testWidgets('a row too narrow for module badges drops them, keeps the chip', (
    tester,
  ) async {
    await _pump(tester, 190, const []);
    final alone = _role(tester);
    await _pump(tester, 190, two);

    expect(_role(tester), alone);
    expect(find.byType(AppBadge), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every badge stays inside the row', (tester) async {
    await _pump(tester, 390, two);

    final row = tester.getRect(find.byType(MemberRow));
    final badges = find.byType(AppBadge);
    expect(badges, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(
        row.right,
        greaterThanOrEqualTo(tester.getRect(badges.at(i)).right),
      );
    }
    expect(tester.takeException(), isNull);
  });
}
