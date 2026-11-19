// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's server logging control (decision 0129): the three modes, each
/// patching only `debug_logging`, and the download of the newest lines.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/theme_file_io.dart';
import 'package:slimm_app/src/features/settings/screens/admin/server_logging_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _Server {
  String mode = 'off';
  bool filesEnabled = true;
  final patches = <Map<String, dynamic>>[];
  final saved = <String, String>{};
}

Future<_Server> _open(
  WidgetTester tester, {
  Size size = const Size(1000, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  final client = MockClient((request) async {
    switch (request.url.path) {
      case '/space/settings':
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          server.patches.add(body);
          server.mode = body['debug_logging'] as String;
        }
        return _json({'join_policy': 'invite', 'debug_logging': server.mode});
      case '/space/server-logs':
        return server.filesEnabled
            ? http.Response(
                'the call dropped here\n',
                200,
                headers: {'content-type': 'text/plain; charset=utf-8'},
              )
            : http.Response(
                '{"error":"this server keeps no log files"}',
                501,
                headers: {'content-type': 'application/json'},
              );
    }
    return http.Response('{"error":"unexpected"}', 404);
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(built.close);
        return built;
      }),
      themeFileSaverProvider.overrideWithValue((name, bytes) async {
        server.saved[name] = utf8.decode(bytes);
        return true;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: ServerLoggingSection()),
        ),
      ),
    ),
  );
  await _frames(tester);
  return server;
}

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1000, 900)),
    ('phone', const Size(390, 900)),
  ]) {
    group(name, () {
      testWidgets('shows the stored mode and Verbose patches only the mode', (
        tester,
      ) async {
        final server = await _open(tester, size: size);

        expect(find.text('Server logging'), findsOneWidget);
        for (final label in ['Off', 'Compact', 'Verbose']) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('Startup, warnings and errors.'), findsOneWidget);

        await tester.tap(find.text('Verbose'));
        await _frames(tester);
        expect(server.patches, [
          {'debug_logging': 'verbose'},
        ]);
        expect(
          find.text('Everything. Older logs are cleared sooner.'),
          findsOneWidget,
        );
      });
    });
  }

  testWidgets('download saves the newest lines as a text file', (tester) async {
    final server = await _open(tester);

    await tester.tap(find.bySemanticsLabel('Download server logs'));
    await _frames(tester);

    expect(server.saved.values.single, 'the call dropped here\n');
    expect(server.saved.keys.single, startsWith('server-log-'));
  });

  testWidgets('a server without log files says so instead of saving', (
    tester,
  ) async {
    final server = await _open(tester);
    server.filesEnabled = false;

    await tester.tap(find.bySemanticsLabel('Download server logs'));
    await _frames(tester);

    expect(server.saved, isEmpty);
    expect(find.text('This server keeps no log files.'), findsOneWidget);
  });
}
