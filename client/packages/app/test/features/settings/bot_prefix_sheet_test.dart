// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bots pane's Prefix sheet: an admin changes the prefix a bot answers to,
/// and a clash the server refuses stays on the sheet as a persistent error.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
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

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _bot(String prefix) => {
  'user_id': 'bot-helper',
  'username': 'helper',
  'display_name': 'Helper',
  'created_at': 0,
  'token_name': 'Helper',
  'token_last_used_at': 1000,
  'role_id': 'role-helper',
  'permissions': 0,
  'online': true,
  'prefix': prefix,
};

http.Response _json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Future<void> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) handler, {
  double width = 800,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
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
        home: const BotsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(AppButton, 'Prefix'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Prefix opens a sheet holding the current prefix', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.url.path == '/bots') return _json([_bot('~')]);
      return _json(<String, Object?>{});
    });
    await _openSheet(tester);

    expect(find.text("Helper's prefix"), findsOneWidget);
    final field = tester.widget<EditableText>(find.byType(EditableText).last);
    expect(field.controller.text, '~');
  });

  testWidgets('saving patches the bot with the new prefix and refetches', (
    tester,
  ) async {
    http.Request? patch;
    var listed = 0;
    await _pump(tester, (request) {
      if (request.method == 'PATCH') {
        patch = request;
        return _json(_bot('?'));
      }
      if (request.url.path == '/bots') {
        listed += 1;
        return _json([_bot(listed == 1 ? '~' : '?')]);
      }
      return _json(<String, Object?>{});
    });
    await _openSheet(tester);
    await tester.enterText(find.byType(EditableText).last, '?');
    await tester.tap(find.widgetWithText(AppButton, 'Save prefix'));
    await tester.pumpAndSettle();

    expect(patch?.url.path, '/bots/bot-helper/prefix');
    expect(jsonDecode(patch!.body), {'prefix': '?'});
    expect(find.text("Helper's prefix"), findsNothing);
    expect(find.textContaining('Prefix ?.'), findsOneWidget);
  });

  testWidgets('a clash the server refuses stays on the sheet as an error', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'PATCH') {
        return _json({
          'error': 'another bot already answers to watch under !',
        }, 409);
      }
      if (request.url.path == '/bots') return _json([_bot('~')]);
      return _json(<String, Object?>{});
    });
    await _openSheet(tester);
    await tester.enterText(find.byType(EditableText).last, '!');
    await tester.tap(find.widgetWithText(AppButton, 'Save prefix'));
    await tester.pumpAndSettle();

    expect(find.text("Helper's prefix"), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.textContaining('Another bot already answers'), findsWidgets);
  });

  testWidgets('an unchanged prefix sends nothing', (tester) async {
    var patched = false;
    await _pump(tester, (request) {
      if (request.method == 'PATCH') patched = true;
      if (request.url.path == '/bots') return _json([_bot('~')]);
      return _json(<String, Object?>{});
    });
    await _openSheet(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Save prefix'));
    await tester.pumpAndSettle();

    expect(patched, isFalse);
    expect(find.text("Helper's prefix"), findsNothing);
  });

  testWidgets('a revoked bot offers no Prefix button', (tester) async {
    await _pump(tester, (request) {
      if (request.url.path == '/bots') {
        return _json([
          {..._bot('~'), 'token_name': null, 'role_id': null},
        ]);
      }
      return _json(<String, Object?>{});
    });

    expect(find.widgetWithText(AppButton, 'Prefix'), findsNothing);
  });

  testWidgets('the sheet fits a phone', (tester) async {
    await _pump(tester, (request) {
      if (request.url.path == '/bots') return _json([_bot('~')]);
      return _json(<String, Object?>{});
    }, width: 390);
    await _openSheet(tester);

    expect(tester.takeException(), isNull);
    final save = tester.getRect(find.widgetWithText(AppButton, 'Save prefix'));
    expect(save.left, greaterThanOrEqualTo(0));
    expect(save.right, lessThanOrEqualTo(390));
  });
}
