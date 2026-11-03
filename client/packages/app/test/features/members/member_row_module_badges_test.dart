// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a narrow member row the name never truncates and no badge is a clipped
/// stub: module badges drop first, the role chip last, the rest fold into +N.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/module_badges.dart';
import 'package:slimm_app/src/features/modules/providers/module_member_badge_settings.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/members/widgets/member_row_badges.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

const _name = 'Ada';

api.UserProfile _member(String role) => api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: _name,
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
  bool shown = true,
}) async {
  SharedPreferences.setMockInitialValues({moduleMemberBadgesKey: shown});
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
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

/// Badges the row actually draws; the ones it hid stay built but not hittable.
Finder _drawn() => find.byType(AppBadge).hitTestable();

Finder _roleChip() => find
    .byWidgetPredicate(
      (w) => w is AppBadge && w.variant == AppBadgeVariant.role,
    )
    .hitTestable();

Size _role(WidgetTester tester) => tester.getSize(_roleChip());

double _natural(Text text) => (TextPainter(
  text: TextSpan(text: text.data, style: text.style),
  textDirection: TextDirection.ltr,
)..layout()).width;

/// Every drawn badge renders its whole label, and the name is not ellipsized.
void _expectWhole(WidgetTester tester) {
  final name = tester.renderObject<RenderParagraph>(find.text(_name));
  expect(name.didExceedMaxLines, isFalse);
  final nameText = tester.widget<Text>(find.text(_name));
  expect(name.size.width, greaterThanOrEqualTo(_natural(nameText) - 0.5));
  for (final badge in _drawn().evaluate()) {
    final label = find.descendant(
      of: find.byWidget(badge.widget),
      matching: find.byType(Text),
    );
    final shown = tester.getSize(label).width;
    expect(
      shown,
      greaterThanOrEqualTo(_natural(tester.widget<Text>(label)) - 0.5),
      reason: 'a badge label was clipped to a stub',
    );
  }
  expect(tester.takeException(), isNull);
}

int _modules(WidgetTester tester) => tester
    .widgetList<AppBadge>(_drawn())
    .where((b) => b.variant != AppBadgeVariant.role && !b.label.startsWith('+'))
    .length;

Finder _moreChip() => find.byType(MemberRowMoreChip).hitTestable();

void main() {
  final two = [_badge('Lv 12'), _badge('Streak 4', 'accent')];

  testWidgets('a wide row shows the role and every module badge whole', (
    tester,
  ) async {
    await _pump(tester, 390, two);

    _expectWhole(tester);
    expect(_modules(tester), 2);
    expect(_moreChip(), findsNothing);
    expect(find.text('Streak 4'), findsOneWidget);
  });

  testWidgets('a long role chip is not squeezed by module badges', (
    tester,
  ) async {
    await _pump(tester, 300, const [], role: 'Administrator');
    final alone = _role(tester);
    await _pump(tester, 300, [
      _badge('Streak 4'),
      _badge('LV 12'),
    ], role: 'Administrator');

    expect(_role(tester), alone);
    _expectWhole(tester);
  });

  testWidgets('the name and badges stay whole at every phone-drawer width', (
    tester,
  ) async {
    final states = <String>{};
    for (var width = 150.0; width <= 480; width += 2) {
      await _pump(tester, width, const []);
      final alone = _roleChip().evaluate().isNotEmpty;
      await _pump(tester, width, two);

      _expectWhole(tester);
      final role = _roleChip();
      if (alone) expect(role, findsOneWidget, reason: 'width $width');
      if (_modules(tester) > 0) {
        expect(role, findsOneWidget, reason: 'role first at $width');
      }
      states.add(
        '${role.evaluate().length}/${_modules(tester)}/'
        '${_moreChip().evaluate().length}',
      );
    }
    expect(states, contains('1/2/0'));
    expect(states.any((s) => s.endsWith('/1')), isTrue);
  });

  testWidgets('the role chip is the same size with and without modules', (
    tester,
  ) async {
    await _pump(tester, 236, const []);
    final alone = _role(tester);
    await _pump(tester, 236, two);

    expect(_role(tester), alone);
    _expectWhole(tester);
  });

  testWidgets('a row too narrow for module badges keeps the role chip', (
    tester,
  ) async {
    await _pump(tester, 190, const []);
    final alone = _role(tester);
    await _pump(tester, 190, two);

    expect(_role(tester), alone);
    expect(_modules(tester), 0);
    _expectWhole(tester);
  });

  testWidgets('what is folded into +N is listed in its tooltip', (
    tester,
  ) async {
    for (var width = 200.0; width <= 330; width += 2) {
      await _pump(tester, width, two);
      if (_moreChip().evaluate().isEmpty) continue;
      final tip = tester.widget<Tooltip>(
        find.descendant(of: _moreChip(), matching: find.byType(Tooltip)).first,
      );
      expect(tip.message, contains('Streak 4'));
      return;
    }
    fail('no width produced an overflow chip');
  });

  testWidgets('a module badge stays out of the member list until it is on', (
    tester,
  ) async {
    await _pump(tester, 390, two, shown: false);
    expect(find.text('Streak 4'), findsNothing);
    expect(_drawn(), findsOneWidget);

    await _pump(tester, 390, two);
    expect(find.text('Streak 4'), findsOneWidget);
  });

  testWidgets('a row badge is quiet: no outline, no origin marker', (
    tester,
  ) async {
    await _pump(tester, 390, [_badge('Lv 8', 'accent')]);

    final badge = tester.widget<AppBadge>(
      find.byWidgetPredicate(
        (w) => w is AppBadge && w.variant != AppBadgeVariant.role,
      ),
    );
    expect(badge.compact, isTrue);
    final box = tester.widget<Container>(
      find.descendant(
        of: find.byWidget(badge),
        matching: find.byWidgetPredicate((w) => w is Container),
      ),
    );
    final border = (box.decoration! as BoxDecoration).border! as Border;
    expect(border.top.color, Colors.transparent);
    expect(find.byIcon(AppIcons.dock), findsNothing);
  });
}
