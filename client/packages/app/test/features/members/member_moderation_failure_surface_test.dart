// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refused moderation write is a persistent error state, shown by the
/// app-level host the pane reports to, never a SnackBar that floats away.
///
/// Covers the bulk timeout and bulk remove in the selection bar, and the row
/// menu's remove: the three that reported through `showAppSnackbar` even
/// though the pane stays on screen.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/member_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_actions.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _priya = UserProfile(
  id: '1',
  username: 'priya',
  displayName: 'Priya',
  createdAt: 0,
);

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

SlimmApi _refusingApi(SessionStore session) => testApi((request) async {
  if (request.url.path == '/me') {
    return http.Response(
      jsonEncode({
        'id': 'self',
        'username': 'self',
        'display_name': 'Self',
        'created_at': 0,
        'permissions': 0,
      }),
      200,
    );
  }
  return http.Response('boom', 500);
}, session: session);

Future<ProviderContainer> _pumpPane(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = _refusingApi(ref.watch(sessionProvider));
        ref.onDispose(api.close);
        return api;
      }),
      membersProvider.overrideWith((ref) async => [_priya]),
      channelMembersProvider.overrideWith((ref, _) async => [_priya]),
      myPermissionsProvider.overrideWithValue(
        Perm.kickMembers | Perm.banMembers,
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        builder: appChromeBuilder,
        home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void _expectPersistentError(String sentence) {
  expect(find.byType(SnackBar), findsNothing);
  expect(find.byType(AppErrorState), findsOneWidget);
  expect(find.textContaining(sentence), findsOneWidget);
}

Future<void> _confirmDialog(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(AppButton, label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a refused bulk timeout stays on screen as an error state', (
    tester,
  ) async {
    final container = await _pumpPane(tester);
    container.read(memberSelectionProvider.notifier).start('1');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AppButton, '5m'));
    await tester.pumpAndSettle();

    _expectPersistentError('time the member out');
    expect(container.read(memberSelectionProvider).contains('1'), isTrue);
  });

  testWidgets('a refused bulk remove stays on screen as an error state', (
    tester,
  ) async {
    final container = await _pumpPane(tester);
    container.read(memberSelectionProvider.notifier).start('1');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AppButton, 'Remove'));
    await tester.pumpAndSettle();
    await _confirmDialog(tester, 'Remove');

    _expectPersistentError('remove the member');
  });

  testWidgets('a refused remove from the row menu stays on screen too', (
    tester,
  ) async {
    final container = await _pumpPane(tester);
    final host = tester.element(find.byType(AppMemberPane));

    final removal = removeMemberFromSpace(host, container, _priya);
    await tester.pumpAndSettle();
    await _confirmDialog(tester, 'Remove');
    await removal;
    await tester.pumpAndSettle();

    _expectPersistentError('remove Priya');
  });

  testWidgets('the error can be dismissed', (tester) async {
    final container = await _pumpPane(tester);
    container.read(memberSelectionProvider.notifier).start('1');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, '5m'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AppButton, 'Dismiss'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsNothing);
  });
}
