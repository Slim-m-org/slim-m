// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile card's linked Discord row: present with a link, absent without,
/// and a tap copies the username.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_links.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) answer,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async => answer(request)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: MemberProfileLinks(userId: 'user-maya')),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

http.Response _links(List<Map<String, Object?>> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// Lets autoDispose providers finish disposing before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('a linked account shows as a row and a tap copies it', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final container = await _pump(tester, (request) {
      expect(request.url.path, '/users/user-maya/links');
      return _links([
        {
          'provider': 'discord',
          'username': 'maya_d',
          'display_name': null,
          'linked_at': 1,
        },
      ]);
    });

    expect(find.textContaining('maya_d'), findsOneWidget);
    await tester.tap(find.textContaining('maya_d'));
    await tester.pumpAndSettle();

    expect(copied, 'maya_d');
    expect(container.read(toastsProvider).single.message, 'Username copied.');
    await tester.pump(const Duration(seconds: 5));
    await _unmount(tester);
  });

  testWidgets('no link, or a failed fetch, draws nothing', (tester) async {
    await _pump(tester, (_) => _links([]));
    expect(find.byType(InkWell), findsNothing);
    expect(find.textContaining('Discord'), findsNothing);

    await _pump(tester, (_) => http.Response('', 500));
    expect(find.textContaining('Discord'), findsNothing);
    await _unmount(tester);
  });
}
