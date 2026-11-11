// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Steam row of Connections: offered only when the server has a key, link
/// and unlink, and the "Share what I'm playing" switch the server holds
/// (decision 0115).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/linked_accounts.dart';
import 'package:slimm_app/src/features/settings/widgets/connections_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _steam({required bool sharing}) => {
  'provider': 'steam',
  'username': 'Ada on Steam',
  'display_name': null,
  'linked_at': 1,
  'share_activity': sharing,
};

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Server {
  _Server({this.steamEnabled = true, this.links = const []});

  bool steamEnabled;
  int startStatus = 200;
  List<Map<String, Object?>> links;
  final requests = <String>[];
  final bodies = <String>[];
  final launched = <Uri>[];

  http.Response answer(http.Request request) {
    requests.add('${request.method} ${request.url.path}');
    if (request.body.isNotEmpty) bodies.add(request.body);
    switch ((request.method, request.url.path)) {
      case ('GET', '/version'):
        return _json(200, {
          'name': 'slim-m',
          'version': '0.94.0',
          'protocol': 1,
          'discord_link_enabled': false,
          'steam_link_enabled': steamEnabled,
        });
      case ('GET', '/me/links'):
        return _json(200, links);
      case ('POST', '/me/links/steam/start'):
        if (startStatus != 200) return http.Response('', startStatus);
        return _json(200, {
          'url': 'https://steamcommunity.com/openid/login?x=1',
        });
      case ('PUT', '/me/links/steam/sharing'):
        final enabled = (jsonDecode(request.body) as Map)['enabled'] as bool;
        links = [_steam(sharing: enabled)];
        return http.Response('', 204);
      case ('DELETE', '/me/links/steam'):
        links = [];
        return http.Response('', 204);
    }
    return _json(404, {});
  }
}

Future<void> _pump(WidgetTester tester, _Server server) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      externalUrlLauncherProvider.overrideWithValue((
        url, {
        mode = LaunchMode.platformDefault,
      }) async {
        server.launched.add(url);
        return true;
      }),
      mockApiOverride((request) async => server.answer(request)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: ConnectionsSection()),
        ),
      ),
    ),
  );
  await waitUntil(
    tester,
    () => server.requests.contains('GET /me/links'),
    reason: 'the links never loaded',
  );
  await pumpFrames(tester);
}

Finder get _shareSwitch => find.byWidgetPredicate(
  (w) => w is AppToggle && w.semanticLabel == "Share what I'm playing",
);

void main() {
  testWidgets('unlinked: Link opens Steam and no switch is offered', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);

    expect(find.text('Steam'), findsOneWidget);
    expect(find.text('Not linked'), findsOneWidget);
    expect(_shareSwitch, findsNothing);

    await tester.tap(find.widgetWithText(AppButton, 'Link'));
    await waitUntil(tester, () => server.launched.isNotEmpty);

    expect(server.launched.single.host, 'steamcommunity.com');
    expect(server.requests, contains('POST /me/links/steam/start'));
  });

  testWidgets('a server without a Steam key offers no Steam row', (
    tester,
  ) async {
    final server = _Server(steamEnabled: false);
    await _pump(tester, server);

    expect(find.text('Steam'), findsNothing);
  });

  testWidgets('linked: shows who, and the switch starts as the server has it', (
    tester,
  ) async {
    final server = _Server(links: [_steam(sharing: false)]);
    await _pump(tester, server);

    expect(find.text('Ada on Steam'), findsOneWidget);
    expect(find.text("Share what I'm playing"), findsOneWidget);
    expect(tester.widget<AppToggle>(_shareSwitch).value, isFalse);
  });

  testWidgets('the switch sends the choice and reads it back', (tester) async {
    final server = _Server(links: [_steam(sharing: false)]);
    await _pump(tester, server);

    await tester.tap(_shareSwitch);
    await waitUntil(
      tester,
      () => server.requests.contains('PUT /me/links/steam/sharing'),
    );
    await pumpFrames(tester);

    expect(server.bodies.last, jsonEncode({'enabled': true}));
    expect(tester.widget<AppToggle>(_shareSwitch).value, isTrue);
  });

  testWidgets('Unlink removes the link and its switch', (tester) async {
    final server = _Server(links: [_steam(sharing: true)]);
    await _pump(tester, server);

    await tester.tap(find.widgetWithText(AppButton, 'Unlink'));
    await waitUntil(
      tester,
      () => server.requests.contains('DELETE /me/links/steam'),
    );
    await pumpFrames(tester);

    expect(find.text('Not linked'), findsOneWidget);
    expect(_shareSwitch, findsNothing);
  });

  testWidgets('a 501 on start takes the row away', (tester) async {
    final server = _Server()..startStatus = 501;
    await _pump(tester, server);

    await tester.tap(find.widgetWithText(AppButton, 'Link'));
    await waitUntil(
      tester,
      () => server.requests.contains('POST /me/links/steam/start'),
    );
    await pumpFrames(tester);

    expect(find.text('Steam'), findsNothing);
  });
}
