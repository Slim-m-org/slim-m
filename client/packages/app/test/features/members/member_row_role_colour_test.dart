// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member row shows roles the way Discord does: no role chip, the name in
/// the colour of the highest role that has one, readable on the pane in both
/// themes, and the default colour when no role has one. A bot keeps its tag.
/// An offline row dims its name, colour and status line with its avatar,
/// never below AA.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/members/widgets/role_color.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/call_header_fixture.dart' show FakePresence;

api.UserProfile _member({
  List<int?> colours = const [null, 6, 2],
  bool bot = false,
  String? status,
}) => api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
  roleIds: const ['r-top', 'r-mid', 'r-low'],
  roles: const ['Founders', 'Moderators', 'Regulars'],
  roleColors: colours,
  isBot: bot,
  statusText: status,
);

Future<void> _pump(
  WidgetTester tester,
  api.UserProfile member, {
  Brightness brightness = Brightness.dark,
  api.PresenceState presence = api.PresenceState.online,
}) => tester.pumpWidget(
  ProviderScope(
    key: UniqueKey(),
    overrides: [
      liveEventsProvider.overrideWithValue(
        const Stream<api.ServerEvent>.empty(),
      ),
      presenceControllerProvider.overrideWith(
        (ref) => FakePresence(ref, {member.id: presence}),
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

    testWidgets('an offline row dims a role colour (${brightness.name})', (
      tester,
    ) async {
      await _pump(tester, _member(), brightness: brightness);
      final online = _nameColour(tester)!;
      await _pump(
        tester,
        _member(),
        brightness: brightness,
        presence: api.PresenceState.offline,
      );
      final offline = _nameColour(tester)!;
      expect(
        HSLColor.fromColor(offline).saturation,
        lessThan(HSLColor.fromColor(online).saturation),
        reason: 'the colour quietens, so it does not shout from Offline',
      );
      expect(
        contrastRatio(offline, tokens.surfaceSunken),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('an offline row dims the default name and status alike '
        '(${brightness.name})', (tester) async {
      await _pump(
        tester,
        _member(colours: const [null, null, null], status: 'away for lunch'),
        brightness: brightness,
        presence: api.PresenceState.offline,
      );
      final name = _nameColour(tester)!;
      final status = tester
          .widget<Text>(find.text('away for lunch'))
          .style
          ?.color;
      final surface = tokens.surfaceSunken;
      expect(name, status);
      expect(
        contrastRatio(name, surface),
        lessThan(contrastRatio(tokens.textSecondary, surface)),
      );
      expect(contrastRatio(name, surface), greaterThanOrEqualTo(4.5));
      final avatar = tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byWidgetPredicate((w) => w is UserAvatar),
              matching: find.byWidgetPredicate((w) => w is Opacity),
            )
            .first,
      );
      expect(avatar.opacity, AppListRow.mutedOpacity);
    });
  }
}
