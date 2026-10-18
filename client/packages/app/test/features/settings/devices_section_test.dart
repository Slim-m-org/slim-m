// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Sign out all other devices" in one action, behind the same confirm sheet
/// each row's own sign-out already uses. See `devices_section.dart`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_account_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _deviceJson(String id, String name, {bool isCurrent = false}) =>
    jsonEncode({
      'id': id,
      'name': name,
      'created_at': 0,
      'last_seen_at': DateTime.now().millisecondsSinceEpoch,
      'is_current': isCurrent,
    });

Future<void> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) handler,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async => handler(request)),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: DevicesSection()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('signing out all other devices removes them and keeps this one', (
    tester,
  ) async {
    final removed = <String>{};
    var devicesFetched = 0;
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/devices') {
        devicesFetched += 1;
        final live = [
          _deviceJson('this', 'This laptop', isCurrent: true),
          if (!removed.contains('phone')) _deviceJson('phone', 'A phone'),
          if (!removed.contains('tablet')) _deviceJson('tablet', 'A tablet'),
        ];
        return http.Response(
          '[${live.join(',')}]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'DELETE') {
        removed.add(request.url.pathSegments.last);
        return http.Response('', 204);
      }
      return http.Response('{}', 404);
    });

    expect(find.text('This laptop'), findsOneWidget);
    expect(find.text('A phone'), findsOneWidget);
    expect(find.text('A tablet'), findsOneWidget);

    await tester.tap(find.text('Sign out others'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out all other devices?'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Sign out all'));
    await tester.pumpAndSettle();

    expect(removed, {'phone', 'tablet'});
    expect(find.text('This laptop'), findsOneWidget);
    expect(find.text('A phone'), findsNothing);
    expect(find.text('A tablet'), findsNothing);
    expect(
      devicesFetched,
      greaterThan(1),
      reason: 'the list must refresh afterwards',
    );
  });

  testWidgets(
    'a partial failure names what is left, rather than claiming success',
    (tester) async {
      final removed = <String>{};
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/devices') {
          final live = [
            _deviceJson('this', 'This laptop', isCurrent: true),
            if (!removed.contains('phone')) _deviceJson('phone', 'A phone'),
            if (!removed.contains('tablet')) _deviceJson('tablet', 'A tablet'),
          ];
          return http.Response(
            '[${live.join(',')}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE' &&
            request.url.pathSegments.last == 'tablet') {
          return http.Response(
            jsonEncode({'error': 'server unavailable'}),
            500,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE') {
          removed.add(request.url.pathSegments.last);
          return http.Response('', 204);
        }
        return http.Response('{}', 404);
      });

      await tester.tap(find.text('Sign out others'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AppButton, 'Sign out all'));
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('A tablet'), findsWidgets);
      expect(
        find.text('A phone'),
        findsNothing,
        reason: 'the one that did succeed still leaves',
      );
    },
  );

  testWidgets(
    'no bulk action is offered when there is nothing else to sign out',
    (tester) async {
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/devices') {
          return http.Response(
            '[${_deviceJson('this', 'This laptop', isCurrent: true)}]',
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });

      expect(find.text('Sign out others'), findsNothing);
    },
  );
}
