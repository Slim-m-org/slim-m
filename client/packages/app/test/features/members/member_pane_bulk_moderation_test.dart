// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the member pane shows right after a bulk moderation call succeeds,
/// with no live event to help: a removed member must be gone at once.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _json(String id, String name) => {
  'id': id,
  'username': name.toLowerCase(),
  'display_name': name,
  'created_at': 0,
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final roster = {'1': 'Priya', '2': 'Kess', '3': 'Dana'};
  final session = SessionStore(tokens: _tokens);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(session),
      apiProvider.overrideWith((ref) {
        final api = testApi((request) async {
          final path = request.url.path;
          if (path == '/members/bulk-removal') {
            final ids = (jsonDecode(request.body)['user_ids'] as List);
            roster.removeWhere((id, _) => ids.contains(id));
            return http.Response('', 204);
          }
          if (path == '/members') {
            return http.Response(
              jsonEncode([
                for (final e in roster.entries) _json(e.key, e.value),
              ]),
              200,
            );
          }
          return http.Response(jsonEncode(const <String, Object?>{}), 200);
        }, session: ref.watch(sessionProvider));
        ref.onDispose(api.close);
        return api;
      }),
      myPermissionsProvider.overrideWithValue(Perm.banMembers),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
      ),
    ),
  );
  await _settle(tester);
  return container;
}

void main() {
  testWidgets('a bulk removal drops the removed rows without a live event', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.bySemanticsLabel('Select members to moderate'));
    await _settle(tester);
    await tester.tap(find.text('Priya'));
    await tester.tap(find.text('Kess'));
    await _settle(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Remove'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Remove').last);
    await _settle(tester);

    expect(find.text('Priya'), findsNothing);
    expect(find.text('Kess'), findsNothing);
    expect(find.text('Dana'), findsOneWidget);
  });
}
