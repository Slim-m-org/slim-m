// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sub-category's permissions sheet opens on whether it follows its parent
/// (decision 0120): following, it only lists who can see it; the switch stops
/// or resumes following, and "Who can see this" is never cut at its card.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/category_permissions_sheet.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import 'category_private_fixture.dart';

const _sub = '/categories/sub';

Future<void> _open(
  WidgetTester tester,
  OverwriteServer server, {
  String? parentName = 'Gamers',
}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const permissions = Perm.administrator | Perm.manageRoles;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: privateTokens),
      ),
      rolesProvider.overrideWith((ref) async => privateRoles),
      membersProvider.overrideWith((ref) async => privateMembers),
      myPermissionsProvider.overrideWith((ref) => permissions),
      roleLadderProvider.overrideWith(
        (ref) => const RoleLadder(permissions: permissions, ranked: false),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCategoryPermissionsSheet(
                context,
                categoryId: 'sub',
                categoryName: 'Gamers / Minecraft',
                parentName: parentName,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpFrames(tester, frames: 20);
}

Finder _toggle(String label) =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == label);

final _follow = _toggle('Follow Gamers');
final _private = _toggle('Private category');

void main() {
  testWidgets('following, it lists who can see it and offers nothing to edit', (
    tester,
  ) async {
    final server = OverwriteServer({_sub: []}, synced: {_sub: true});
    await _open(tester, server);

    expect(_follow, findsOneWidget);
    expect(find.text('Uses the same permissions as Gamers.'), findsOneWidget);
    expect(find.text('Everyone'), findsOneWidget);
    expect(_private, findsNothing, reason: 'its access comes from Gamers');
    expect(find.byKey(categoryAdvancedToggleKey), findsNothing);
  });

  testWidgets('turning it off saves nothing new and shows its own settings', (
    tester,
  ) async {
    final server = OverwriteServer({_sub: []}, synced: {_sub: true});
    await _open(tester, server);

    await tapAndWait(tester, _follow, server);
    await pumpFrames(tester);

    expect(server.writes[_sub], isEmpty);
    expect(find.text('Has its own permissions.'), findsOneWidget);
    expect(_private, findsOneWidget);
    expect(find.byKey(categoryAdvancedToggleKey), findsOneWidget);
  });

  testWidgets('turning it on asks first, then syncs with the parent', (
    tester,
  ) async {
    final server = OverwriteServer({_sub: []}, synced: {_sub: false});
    await _open(tester, server);

    await tester.tap(_follow);
    await pumpFrames(tester);
    expect(find.text('Follow Gamers?'), findsOneWidget);
    await tapAndWait(tester, find.text('Follow'), server);
    await pumpFrames(tester);

    expect(server.requests, contains('POST /categories/sub/overwrites/sync'));
    expect(_private, findsNothing);
  });

  testWidgets('a top-level category has no follow switch', (tester) async {
    final server = OverwriteServer({_sub: []});
    await _open(tester, server, parentName: null);

    expect(find.textContaining('Follow'), findsNothing);
    expect(_private, findsOneWidget);
  });

  testWidgets('the last person who can see it sits clear of the card edge', (
    tester,
  ) async {
    final server = OverwriteServer({_sub: []}, synced: {_sub: true});
    await _open(tester, server);

    final row = tester.getRect(find.text('Everyone'));
    final card = tester.getRect(
      find
          .ancestor(
            of: find.text('Everyone'),
            matching: find.byWidgetPredicate((w) => w is ClipRRect),
          )
          .first,
    );
    expect(card.bottom - row.bottom, greaterThanOrEqualTo(AppSpacing.s12));
  });
}
