// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Re-issuing a bot's token from the Bots pane: asked first, then shown once
/// with the same copy actions a new bot gets.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/bots_screen.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _newToken = 'slimbot_fresh0123456789';

Map<String, dynamic> _bot({String? tokenName = 'Helper', String suffix = ''}) =>
    {
      'user_id': 'bot-helper$suffix',
      'username': 'helper$suffix',
      'display_name': 'helper$suffix',
      'created_at': 0,
      'token_name': tokenName,
      'role_id': tokenName == null ? null : 'role-helper',
      'permissions': 0,
      'online': false,
    };

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Future<List<String>> _pump(
  WidgetTester tester, {
  String? tokenName = 'Helper',
  int reissueStatus = 200,
  int botCount = 1,
  Size size = const Size(800, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final posted = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'user-1',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      mockApiOverride((request) async {
        if (request.method == 'POST' &&
            request.url.path.startsWith('/bots/bot-helper') &&
            request.url.path.endsWith('/token')) {
          posted.add(request.url.path);
          return reissueStatus == 200
              ? _json({'bot': _bot(), 'token': _newToken})
              : _json({'error': 'no such bot'}, reissueStatus);
        }
        if (request.method == 'GET' && request.url.path == '/bots') {
          return _json([
            for (var i = 0; i < botCount; i++)
              _bot(tokenName: tokenName, suffix: i == 0 ? '' : '$i'),
          ]);
        }
        return http.Response('[]', 200);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const BotsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return posted;
}

void main() {
  testWidgets('re-issuing asks first and posts nothing until confirmed', (
    tester,
  ) async {
    final posted = await _pump(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue token'));
    await tester.pumpAndSettle();

    expect(find.text("Re-issue helper's token?"), findsOneWidget);
    expect(posted, isEmpty);

    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(posted, isEmpty);
    expect(find.textContaining(_newToken), findsNothing);
  });

  testWidgets('confirming shows the new token once, with the env block', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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
    final posted = await _pump(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue token'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
    await tester.pumpAndSettle();

    expect(posted, ['/bots/bot-helper/token']);
    expect(find.textContaining(_newToken), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Copy env block'));
    await tester.pump();
    expect(copied, contains('SLIMM_BOT_TOKEN=$_newToken'));

    await tester.tap(find.widgetWithText(AppButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining(_newToken), findsNothing);
  });

  testWidgets('a revoked bot can be re-issued a token', (tester) async {
    await _pump(tester, tokenName: null);
    expect(find.widgetWithText(AppButton, 'Re-issue token'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Revoke'), findsNothing);
    expect(find.widgetWithText(AppButton, 'Permissions'), findsNothing);
  });

  testWidgets('a refused re-issue stays inline and shows no token', (
    tester,
  ) async {
    await _pump(tester, reissueStatus: 404);
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue token'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining(_newToken), findsNothing);
  });

  testWidgets('a re-issue from a low row brings the token into view', (
    tester,
  ) async {
    await _pump(tester, botCount: 8, size: const Size(390, 844));
    final last = find.widgetWithText(AppButton, 'Re-issue token').last;
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
    await tester.pumpAndSettle();

    final token = find.textContaining(_newToken);
    expect(token, findsOneWidget);
    final box = tester.getRect(token);
    expect(box.top, greaterThanOrEqualTo(0));
    expect(box.bottom, lessThanOrEqualTo(844));
  });

  testWidgets('a token nobody has copied is not overwritten by another', (
    tester,
  ) async {
    await _pump(tester, botCount: 2);
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue token').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
    await tester.pumpAndSettle();

    final buttons = tester.widgetList<AppButton>(
      find.widgetWithText(AppButton, 'Re-issue token'),
    );
    expect(buttons.every((b) => b.onPressed == null), isTrue);
  });
}
