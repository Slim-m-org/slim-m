// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member pane's selection bar and its moderation sheet, at phone and
/// desktop width.
///
/// The phone renders are the ones that matter: the pane is a 236px drawer
/// there, and the bar used to stack every verb into it. Same split as the
/// sibling overlay files: the overflow assertion runs everywhere, the PNGs
/// only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_moderation_error.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/member_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

api.UserProfile _profile(String id, String name) => api.UserProfile(
  id: id,
  username: name.toLowerCase(),
  displayName: name,
  createdAt: 0,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required Size window,
  required bool drawer,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final roster = [
    _profile('1', 'Priya'),
    _profile('2', 'Kess'),
    _profile('3', 'Marco'),
    _profile('4', 'Dana'),
  ];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      membersProvider.overrideWith((ref) async => roster),
      channelMembersProvider.overrideWith((ref, _) async => roster),
      myPermissionsProvider.overrideWithValue(
        Perm.kickMembers | Perm.banMembers,
      ),
    ],
  );
  addTearDown(container.dispose);
  final scaffoldKey = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            key: scaffoldKey,
            endDrawer: drawer
                ? const Drawer(
                    width: AppMemberPane.width,
                    child: SafeArea(child: AppMemberPane(channelId: 'c1')),
                  )
                : null,
            body: drawer
                ? const Center(child: Text('#general'))
                : const Align(
                    alignment: Alignment.centerRight,
                    child: AppMemberPane(channelId: 'c1'),
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (drawer) scaffoldKey.currentState!.openEndDrawer();
  await tester.pumpAndSettle();
  container.read(memberSelectionProvider.notifier)
    ..enter()
    ..toggle('1');
  await tester.pumpAndSettle();
  return container;
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('phone: the drawer holds one slim bar', (tester) async {
    await _pump(tester, window: const Size(390, 844), drawer: true);
    await _finish(tester, 'member-selection-phone-bar');
  });

  testWidgets('phone: the moderation sheet', (tester) async {
    await _pump(tester, window: const Size(390, 844), drawer: true);
    await tester.tap(find.text('Moderate'));
    await tester.pumpAndSettle();
    await _finish(tester, 'member-selection-phone-sheet');
  });

  testWidgets('desktop: the pane keeps its stacked bar', (tester) async {
    await _pump(tester, window: const Size(1280, 800), drawer: false);
    await _finish(tester, 'member-selection-desktop');
  });

  testWidgets('phone: a refused write stays above the bar', (tester) async {
    final container = await _pump(
      tester,
      window: const Size(390, 844),
      drawer: true,
    );
    container.read(memberModerationErrorProvider.notifier).state =
        'Could not time the member out. Try again in a moment.';
    await tester.pumpAndSettle();
    await _finish(tester, 'member-selection-phone-error');
  });
}
