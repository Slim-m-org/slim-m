// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The module page's "Badge in member list" switch: off until chosen, kept per
/// module, and remembered across launches.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/modules/providers/module_member_badge_settings.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_member_badge_card.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../dock_manifest_fixture.dart';

const _label = 'Show this module badge in the member list';

Future<ProviderContainer> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: DockMemberBadgeCard(moduleId: 'xp')),
      ),
    ),
  );
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  return container;
}

Future<void> _pumpPage(WidgetTester tester, List<Object> slots) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DockManifestView(
              manifest: api.DockManifest.fromJson(
                dockManifestJson('xp', '1.0.0'),
              ),
              installed: api.InstalledDockModule.fromJson({
                'id': 'xp',
                'name': 'xp',
                'version': '1.0.0',
                'artifact_sha256': 'a' * 64,
                'approved_capabilities': <String>[],
                'extension_points': <Object>[],
                'enabled': true,
                'installed_at': 1,
                'slots': slots,
              }),
              busy: false,
              error: null,
              onErrorDismiss: () {},
              onInstall: () {},
              onSetEnabled: (_) {},
              onUninstall: () {},
              onChooseAccess: () {},
              approvedHostCapabilities: const {},
              onToggleHostCapability: (_, _) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('only a module with a member.badge slot gets the switch', (
    tester,
  ) async {
    await _pumpPage(tester, [
      {'kind': 'member.badge', 'name': 'level'},
    ]);
    expect(find.bySemanticsLabel(_label), findsOneWidget);

    await _pumpPage(tester, [
      {'kind': 'profile.section', 'name': 'level'},
    ]);
    expect(find.bySemanticsLabel(_label), findsNothing);
  });

  testWidgets('the switch starts off and turns one module on and off', (
    tester,
  ) async {
    final container = await _pump(tester);
    expect(container.read(moduleMemberBadgeSettingsProvider), isEmpty);

    await tester.tap(find.bySemanticsLabel(_label));
    await tester.pump();
    expect(container.read(moduleMemberBadgeSettingsProvider), {'xp'});

    await tester.tap(find.bySemanticsLabel(_label));
    await tester.pump();
    expect(container.read(moduleMemberBadgeSettingsProvider), isEmpty);
  });

  testWidgets('the choice is written to preferences', (tester) async {
    final container = await _pump(tester);

    await tester.tap(find.bySemanticsLabel(_label));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getStringList(moduleMemberBadgesKey), ['xp']);
    expect(container.read(moduleMemberBadgeSettingsProvider), {'xp'});
  });
}
