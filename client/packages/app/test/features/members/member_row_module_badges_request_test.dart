// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A roster row asks for module badges only while the Space shows them, since
/// the setting defaults to off and every ask is a request to the server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/module_badges.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane_rows.dart';
import 'package:slimm_app/src/features/modules/providers/module_display_settings.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_design_system/design_system.dart';

const _member = api.UserProfile(
  id: 'ada',
  username: 'ada',
  displayName: 'Ada',
  createdAt: 0,
);

final _shown = StateProvider<bool>((ref) => false);

class _Recording extends ModuleBadgesController {
  _Recording(super.ref, this.asked);

  final List<String> asked;

  @override
  void request(String id) => asked.add(id);
}

Future<void> _pump(WidgetTester tester, List<String> asked) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        liveEventsProvider.overrideWithValue(
          const Stream<api.ServerEvent>.empty(),
        ),
        moduleBadgesProvider.overrideWith((ref) => _Recording(ref, asked)),
        moduleMemberBadgesShownProvider.overrideWith(
          (ref) => ref.watch(_shown),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: MemberRow(profile: _member, isSelf: false)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a row on a Space with badges off asks for none', (tester) async {
    final asked = <String>[];
    await _pump(tester, asked);

    expect(find.text('Ada'), findsOneWidget);
    expect(asked, isEmpty);
  });

  testWidgets('the row asks once the setting turns on', (tester) async {
    final asked = <String>[];
    await _pump(tester, asked);

    ProviderScope.containerOf(
      tester.element(find.text('Ada')),
    ).read(_shown.notifier).state = true;
    await tester.pump();

    expect(asked, ['ada']);
  });
}
