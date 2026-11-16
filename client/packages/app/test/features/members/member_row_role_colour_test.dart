// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member row shows roles the way Discord does: no role chip, the name in
/// the colour of the highest role that has one, readable on the pane in both
/// themes, and the default colour when no role has one. A bot keeps its tag.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/members/widgets/role_color.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

api.UserProfile _member({
  List<int?> colours = const [null, 6, 2],
  bool bot = false,
}) => api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
  roleIds: const ['r-top', 'r-mid', 'r-low'],
  roles: const ['Founders', 'Moderators', 'Regulars'],
  roleColors: colours,
  isBot: bot,
);

Future<void> _pump(
  WidgetTester tester,
  api.UserProfile member, {
  Brightness brightness = Brightness.dark,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      liveEventsProvider.overrideWithValue(
        const Stream<api.ServerEvent>.empty(),
      ),
    ],
    child: MaterialApp(
      theme: buildTheme(
        brightness,
        brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 236,
            child: MemberRow(profile: member, isSelf: false),
          ),
        ),
      ),
    ),
  ),
);

Finder _badges() => find.byWidgetPredicate((w) => w is AppBadge).hitTestable();

Color? _nameColour(WidgetTester tester) =>
    tester.widget<Text>(find.text('Ada')).style?.color;

void main() {
  testWidgets('a member with roles carries no role chip', (tester) async {
    await _pump(tester, _member());
    expect(_badges(), findsNothing);
    expect(find.text('Founders'), findsNothing);
  });

  testWidgets('a bot keeps its Bot tag', (tester) async {
    await _pump(tester, _member(bot: true));
    expect(_badges(), findsOneWidget);
    expect(tester.widget<AppBadge>(_badges()).label, 'Bot');
  });

  for (final brightness in Brightness.values) {
    final tokens = brightness == Brightness.dark
        ? AppTokens.dark
        : AppTokens.light;

    testWidgets('the name wears the top coloured role (${brightness.name})', (
      tester,
    ) async {
      await _pump(tester, _member(), brightness: brightness);
      final colour = _nameColour(tester)!;
      final red = rolePalette[6].color;
      expect(colour, isNot(tokens.textSecondary));
      expect(
        HSLColor.fromColor(colour).hue,
        closeTo(HSLColor.fromColor(red).hue, 1),
        reason: 'the uncoloured top role is skipped, the next one wins',
      );
      expect(
        contrastRatio(colour, tokens.surfaceSunken),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('no coloured role keeps the default (${brightness.name})', (
      tester,
    ) async {
      await _pump(
        tester,
        _member(colours: const [null, null, null]),
        brightness: brightness,
      );
      expect(_nameColour(tester), tokens.textSecondary);
    });
  }
}
