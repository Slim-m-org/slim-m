// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Connections section: Discord link, unlink, refresh, and the 501 that
/// hides it. See `connections_section.dart`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/linked_accounts.dart';
import 'package:slimm_app/src/features/settings/widgets/connections_section.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const linkedJson = {
  'provider': 'discord',
  'username': 'nick_d',
  'display_name': 'Nick',
  'linked_at': 1,
};

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Harness {
  _Harness(this.container);

  final ProviderContainer container;
  final launched = <Uri>[];
  final requests = <String>[];
}

Future<_Harness> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) answer,
) async {
  late final _Harness harness;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      externalUrlLauncherProvider.overrideWithValue((
        url, {
        mode = LaunchMode.platformDefault,
      }) async {
        harness.launched.add(url);
        return true;
      }),
      apiProvider.overrideWith((ref) {
        final built = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            harness.requests.add('${request.method} ${request.url.path}');
            return answer(request);
          }),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  harness = _Harness(container);
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
  await tester.pumpAndSettle();
  return harness;
}

/// Lets autoDispose providers finish disposing before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('unlinked: Link starts the flow and opens the url', (
    tester,
  ) async {
    final h = await _pump(tester, (request) {
      if (request.url.path == '/me/links') return _json(200, []);
      if (request.url.path == '/me/links/discord/start') {
        return _json(200, {'url': 'https://discord.com/oauth2/authorize?x=1'});
      }
      return _json(404, {});
    });
    expect(find.text('Not linked'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Link'));
    await tester.pumpAndSettle();

    expect(
      h.launched.single.toString(),
      'https://discord.com/oauth2/authorize?x=1',
    );
    expect(h.requests, contains('POST /me/links/discord/start'));
    await _unmount(tester);
  });

  testWidgets('a 501 on start hides the whole section', (tester) async {
    await _pump(tester, (request) {
      if (request.url.path == '/me/links') return _json(200, []);
      return http.Response('', 501);
    });
    await tester.tap(find.widgetWithText(AppButton, 'Link'));
    await tester.pumpAndSettle();

    expect(find.text('Connections'), findsNothing);
    expect(find.text('Discord'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a server without Discord hides the section up front', (
    tester,
  ) async {
    final h = await _pump(tester, (request) {
      if (request.url.path == '/version') {
        return _json(200, {
          'name': 'slim-m',
          'version': '0.94.0',
          'protocol': 1,
          'discord_link_enabled': false,
        });
      }
      if (request.url.path == '/me/links') return _json(200, []);
      return _json(404, {});
    });

    expect(find.text('Connections'), findsNothing);
    expect(h.requests, isNot(contains('POST /me/links/discord/start')));
    await _unmount(tester);
  });

  testWidgets('linked: shows the name and Unlink removes it', (tester) async {
    var linked = true;
    final h = await _pump(tester, (request) {
      if (request.method == 'DELETE') {
        linked = false;
        return http.Response('', 204);
      }
      return _json(200, linked ? [linkedJson] : []);
    });
    expect(find.text('Nick (nick_d)'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Unlink'));
    await tester.pumpAndSettle();

    expect(h.requests, contains('DELETE /me/links/discord'));
    expect(find.text('Not linked'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a failed start shows an inline error, not a snack bar', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.url.path == '/me/links') return _json(200, []);
      return _json(500, {'error': 'boom'});
    });
    await tester.tap(find.widgetWithText(AppButton, 'Link'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Connections'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('refreshing, by button or on resume, refetches the links', (
    tester,
  ) async {
    var linked = false;
    final h = await _pump(tester, (request) {
      return _json(200, linked ? [linkedJson] : []);
    });
    expect(find.text('Not linked'), findsOneWidget);

    linked = true;
    await tester.tap(find.byTooltip('Refresh connections'));
    await tester.pumpAndSettle();
    expect(find.text('Nick (nick_d)'), findsOneWidget);

    linked = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Not linked'), findsOneWidget);
    expect(h.requests.where((r) => r == 'GET /me/links').length, 3);
    expect(h.container.read(appFocusedProvider), isTrue);
    await _unmount(tester);
  });
}
