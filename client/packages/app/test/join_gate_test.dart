// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join gate from the client's side: the banner and rules sheet a waiting
/// member sees, and the admin section that sets the gate up.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/join_gate_section.dart';
import 'package:slimm_app/src/widgets/rules_gate_banner_host.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// A fake server with the gate's routes; [requests] records every call.
class _Server {
  bool pending = true;
  Map<String, dynamic> gate = {
    'enabled': false,
    'rules': '',
    'rules_channel_id': null,
    'joins_paused': false,
  };
  final requests = <String>[];
  final puts = <Map<String, dynamic>>[];

  MockClient get client => MockClient((request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    return switch ((request.method, path)) {
      ('GET', '/space/rules') => _json({
        'rules': 'Be kind.\nNo spam.',
        'rules_channel_id': null,
        'pending': pending,
      }),
      ('POST', '/space/rules/accept') => () {
        pending = false;
        return http.Response('', 204);
      }(),
      ('GET', '/space/join-gate') => _json(gate),
      ('PUT', '/space/join-gate') => () {
        gate = jsonDecode(request.body) as Map<String, dynamic>;
        puts.add(gate);
        return _json(gate);
      }(),
      ('GET', '/channels') => _json([
        {
          'id': 'c-rules',
          'name': 'rules',
          'kind': 'text',
          'position': 0,
          'created_at': 1,
        },
        {
          'id': 'c-voice',
          'name': 'hangout',
          'kind': 'voice',
          'position': 1,
          'created_at': 1,
        },
      ]),
      _ => _json({'error': 'not found'}, 404),
    };
  });
}

Future<void> _pump(
  WidgetTester tester,
  _Server server,
  Widget child, {
  bool scrolls = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: server.client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: scrolls ? SingleChildScrollView(child: child) : child,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a waiting member reads the rules, accepts, and the banner goes',
    (tester) async {
      final server = _Server();
      await _pump(
        tester,
        server,
        const RulesGateBannerHost(child: Text('shell')),
      );

      expect(find.text('shell'), findsOneWidget);
      expect(find.byType(RulesGateBanner), findsOneWidget);
      await tester.tap(find.text('Read the rules'));
      await tester.pumpAndSettle();
      expect(find.text('Be kind.\nNo spam.'), findsOneWidget);

      await tester.tap(find.text('I accept the rules'));
      await tester.pumpAndSettle();
      expect(server.requests, contains('POST /space/rules/accept'));
      expect(find.byType(RulesSheet), findsNothing);
      expect(find.byType(RulesGateBanner), findsNothing);
    },
  );

  testWidgets('a member who already accepted sees no banner', (tester) async {
    final server = _Server()..pending = false;
    await _pump(
      tester,
      server,
      const RulesGateBannerHost(child: Text('shell')),
    );
    expect(find.byType(RulesGateBanner), findsNothing);
  });

  testWidgets('a server without a gate shows no banner', (tester) async {
    final server = _Server();
    final old = MockClient((_) async => _json({'error': 'not found'}, 404));
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: old,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const RulesGateBannerHost(child: Text('shell')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RulesGateBanner), findsNothing);
    expect(server.requests, isEmpty);
  });

  testWidgets('a broken rules response never takes the shell down', (
    tester,
  ) async {
    final broken = MockClient((_) async => _json(const []));
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: broken,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const RulesGateBannerHost(child: Text('shell')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('shell'), findsOneWidget);
    expect(find.byType(RulesGateBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turning the gate on needs rules, then saves the whole form', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, const JoinGateSection(), scrolls: true);

    await tester.tap(find.byType(AppToggle).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('Write the rules before turning this on.'),
      findsOneWidget,
    );
    expect(server.puts, isEmpty);

    await tester.enterText(find.byType(TextField), '  Be kind.  ');
    await tester.tap(find.text('Rules channel'));
    await tester.pumpAndSettle();
    expect(
      find.text('#hangout'),
      findsNothing,
      reason: 'voice channels are not offered',
    );
    await tester.tap(find.text('#rules'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppToggle).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(server.puts.single, {
      'enabled': true,
      'rules': 'Be kind.',
      'rules_channel_id': 'c-rules',
      'joins_paused': true,
    });
  });
}
