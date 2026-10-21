// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bots pane: creating one reveals its token exactly once, a listing never
/// carries a token, and revoking one keeps it on screen with no live token.
///
/// The reveal is the part worth testing hardest. The server keeps only a hash,
/// so a token lost between the response and the operator's clipboard is a bot
/// that has to be thrown away and made again. That makes "the token is still on
/// screen after a rebuild" a correctness property rather than a nicety.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/bots_screen.dart';
import 'package:slimm_app/src/widgets/toast_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _botToken = 'slimbot_abcdef0123456789';

String _botJson(
  String username, {
  String? tokenName = 'Helper',
  int? lastUsed,
  int permissions = 0,
  bool online = false,
}) => jsonEncode({
  'user_id': 'bot-$username',
  'username': username,
  'display_name': username,
  'created_at': 0,
  'token_name': tokenName,
  'token_last_used_at': lastUsed,
  'role_id': tokenName == null ? null : 'role-$username',
  'permissions': permissions,
  'online': online,
});

Future<void> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) handler, {
  int mine = 0,
  double width = 800,
  Stream<ServerEvent>? events,
}) async {
  // Taller than 600px default: the permission list pushes buttons off-screen.
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      liveEventsProvider.overrideWithValue(events ?? const Stream.empty()),
      myPermissionsProvider.overrideWithValue(mine),
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
        builder: (context, child) => Stack(
          children: [
            child ?? const SizedBox.shrink(),
            const Positioned.fill(child: ToastOverlay()),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('creating a bot shows its token, and keeps showing it', (
    tester,
  ) async {
    var created = false;
    await _pump(tester, (request) {
      if (request.method == 'POST' && request.url.path == '/bots') {
        created = true;
        return http.Response(
          jsonEncode({
            'bot': jsonDecode(_botJson('helper')),
            'token': _botToken,
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          created ? '[${_botJson('helper')}]' : '[]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    await tester.enterText(find.byType(TextField).first, 'helper');
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();

    expect(find.text(_botToken), findsOneWidget);

    // A rebuild must not take it away; there is no second chance to read it.
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(_botToken), findsOneWidget);
  });

  testWidgets('the token is dismissed only when the operator says so', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'POST' && request.url.path == '/bots') {
        return http.Response(
          jsonEncode({
            'bot': jsonDecode(_botJson('helper')),
            'token': _botToken,
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response(
        '[]',
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    await tester.enterText(find.byType(TextField).first, 'helper');
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();
    expect(find.text(_botToken), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Done'));
    await tester.pumpAndSettle();

    expect(find.text(_botToken), findsNothing);
  });

  testWidgets('a listed bot never shows a token, only whether it has one', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          '[${_botJson('helper', lastUsed: 1000)}]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    expect(find.text('@helper'), findsOneWidget);
    expect(find.textContaining('Last seen'), findsOneWidget);
    expect(
      find.textContaining('slimbot_'),
      findsNothing,
      reason:
          'the listing response carries no token, so nothing can render one',
    );
  });

  testWidgets('a connected bot reads Online and an idle one Offline', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          '[${_botJson('live', online: true)},'
          '${_botJson('idle', lastUsed: DateTime.now().millisecondsSinceEpoch)}]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.textContaining('Last seen just now.'), findsOneWidget);
    expect(find.text('Never connected.'), findsNothing);
  });

  testWidgets(
    'a bot that never connected says so, and a revoked one is quiet',
    (tester) async {
      await _pump(tester, (request) {
        if (request.method == 'GET' && request.url.path == '/bots') {
          return http.Response(
            '[${_botJson('fresh')},${_botJson('gone', tokenName: null)}]',
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      expect(find.textContaining('Never connected.'), findsOneWidget);
      expect(
        find.text('Offline'),
        findsOneWidget,
        reason: 'revoked has no badge',
      );
    },
  );

  testWidgets('a presence change for a listed bot refetches the list', (
    tester,
  ) async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    var online = false;
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          '[${_botJson('helper', online: online)}]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    }, events: events.stream);
    expect(find.text('Offline'), findsOneWidget);

    online = true;
    events.add(
      const PresenceChanged(userId: 'bot-helper', status: PresenceState.online),
    );
    await tester.pumpAndSettle();

    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('a new bot offers the env block, and it is never drawn', (
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
    await _pump(tester, (request) {
      if (request.method == 'POST' && request.url.path == '/bots') {
        return http.Response(
          jsonEncode({
            'bot': jsonDecode(_botJson('helper')),
            'token': _botToken,
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
    });

    await tester.enterText(find.byType(TextField).first, 'helper');
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Copy env block'));
    await tester.pump();

    expect(
      copied,
      'SLIMM_URL=http://localhost:8080\nSLIMM_BOT_TOKEN=$_botToken\n',
    );
    expect(find.textContaining('SLIMM_BOT_TOKEN'), findsNothing);

    await tester.tap(find.widgetWithText(AppButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppButton, 'Copy env block'), findsNothing);
  });

  testWidgets('a revoked bot stays listed, with no Revoke button left', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          '[${_botJson('helper', tokenName: null)}]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    expect(
      find.text('@helper'),
      findsOneWidget,
      reason: 'the account stays, so what it wrote stays attributed to it',
    );
    expect(
      find.textContaining('Revoked. Re-issue a token to bring it back.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(AppButton, 'Revoke'), findsNothing);
  });

  Future<List<String>> openRevoke(WidgetTester tester) async {
    final posted = <String>[];
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          '[${_botJson('helper')}]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST') {
        posted.add(request.url.path);
        return http.Response('', 204);
      }
      return http.Response('{}', 200);
    });
    await tester.tap(find.widgetWithText(AppButton, 'Revoke'));
    await tester.pumpAndSettle();
    return posted;
  }

  testWidgets('revoking asks first and posts nothing until it is confirmed', (
    tester,
  ) async {
    final posted = await openRevoke(tester);

    expect(find.text('Revoke helper?'), findsOneWidget);
    expect(posted, isEmpty);
  });

  testWidgets('confirming revokes that bot', (tester) async {
    final posted = await openRevoke(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Revoke').last);
    await tester.pumpAndSettle();

    expect(posted, ['/bots/bot-helper/revoke']);
  });

  testWidgets('cancelling revokes nothing', (tester) async {
    final posted = await openRevoke(tester);

    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(posted, isEmpty);
    expect(find.text('Revoke helper?'), findsNothing);
  });

  testWidgets('the create form folds its permissions until asked', (
    tester,
  ) async {
    await _pump(tester, (request) => http.Response('[]', 200));

    expect(find.byType(AppToggle), findsNothing);
    expect(find.text('None granted'), findsOneWidget);

    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();

    expect(find.byType(AppToggle), findsWidgets);
  });

  AppToggle toggle(WidgetTester tester, String label) => tester
      .widgetList<AppToggle>(find.byType(AppToggle))
      .firstWhere((t) => t.semanticLabel == label);

  testWidgets('creating a bot sends its username and the permissions picked', (
    tester,
  ) async {
    Map<String, dynamic>? body;
    await _pump(tester, (request) {
      if (request.method == 'POST' && request.url.path == '/bots') {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'bot': jsonDecode(_botJson('helper')),
            'token': _botToken,
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
    }, mine: Perm.sendMessages | Perm.viewChannel);

    await tester.enterText(find.byType(TextField).first, 'helper');
    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();
    toggle(tester, 'Send messages').onChanged!(true);
    await tester.pump();
    expect(find.text('1 granted'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();

    expect(body?['username'], 'helper');
    expect(body?['permissions'], Perm.sendMessages);
  });

  testWidgets('the form offers a free prefix and sends the one left in it', (
    tester,
  ) async {
    Map<String, dynamic>? body;
    await _pump(tester, (request) {
      if (request.url.path == '/bots/suggested-prefix') {
        return http.Response(
          jsonEncode({'prefix': '?'}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (request.method == 'POST' && request.url.path == '/bots') {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'bot': jsonDecode(_botJson('helper')),
            'token': _botToken,
          }),
          201,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('[]', 200);
    });

    final prefixField = find.bySemanticsLabel('Bot command prefix');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      '?',
    );
    expect(prefixField, findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'helper');
    await tester.enterText(find.byType(TextField).at(1), '~');
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();

    expect(body?['prefix'], '~');
  });

  testWidgets('a listed bot shows the prefix it answers to', (tester) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        final bot = jsonDecode(_botJson('helper', lastUsed: 1000));
        bot['prefix'] = '~';
        return http.Response(
          jsonEncode([bot]),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    });

    expect(find.textContaining('Prefix ~.'), findsOneWidget);
  });

  testWidgets('a permission the admin lacks cannot be granted to a new bot', (
    tester,
  ) async {
    await _pump(
      tester,
      (request) => http.Response('[]', 200),
      mine: Perm.viewChannel,
    );
    await tester.tap(find.text('Permissions'));
    await tester.pumpAndSettle();

    expect(toggle(tester, 'View channels').onChanged, isNotNull);
    expect(toggle(tester, 'Manage roles').onChanged, isNull);
  });

  testWidgets('an empty username creates nothing', (tester) async {
    var posted = false;
    await _pump(tester, (request) {
      if (request.method == 'POST') posted = true;
      return http.Response('[]', 200);
    });
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();
    expect(posted, isFalse);
  });

  testWidgets('a failed create stays on the form as a persistent error', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'POST') return http.Response('down', 500);
      return http.Response('[]', 200);
    });
    await tester.enterText(find.byType(TextField).first, 'helper');
    await tester.tap(find.widgetWithText(AppButton, 'Create bot'));
    await tester.pumpAndSettle();
    expect(find.textContaining('create the bot'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('with no bots the list says so', (tester) async {
    await _pump(tester, (request) => http.Response('[]', 200));
    expect(find.text('No bots yet.'), findsOneWidget);
  });

  testWidgets('a listed bot fits a phone with both actions', (tester) async {
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/bots') {
        return http.Response(
          '[${_botJson('helper', lastUsed: 1000, permissions: 3)}]',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 200);
    }, width: 360);
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(AppButton, 'Permissions'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Revoke'), findsOneWidget);
  });
}
