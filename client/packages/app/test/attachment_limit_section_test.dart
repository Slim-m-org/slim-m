// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment size limit control on the Space performance screen: it
/// offers the presets that fit under the operator's ceiling and patches the
/// chosen one. Its own file because `performance_screen_test.dart` is at its
/// file-size ceiling.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/attachment_limit_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _mib = 1024 * 1024;
const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Widget _app(MockClient client) => ProviderScope(
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
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: const Scaffold(
      body: SingleChildScrollView(child: AttachmentLimitSection()),
    ),
  ),
);

MockClient _server({
  required int serverMax,
  int current = 0,
  List<int>? patches,
  bool refusePatch = false,
}) {
  var maxBytes = current;
  return MockClient((request) async {
    if (request.method == 'PATCH') {
      if (refusePatch) return _json({'error': 'out of range'}, 400);
      maxBytes = (jsonDecode(request.body) as Map)['max_bytes'] as int;
      patches?.add(maxBytes);
    }
    return _json({'max_bytes': maxBytes, 'server_max_bytes': serverMax});
  });
}

void main() {
  testWidgets('offers only the presets under the server maximum', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_server(serverMax: 2048 * _mib)));
    await tester.pumpAndSettle();

    expect(find.text('Attachment size limit'), findsWidgets);
    expect(find.text('Largest file a member can upload.'), findsOneWidget);
    for (final label in ['25 MB', '100 MB', '500 MB', '1 GB']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('5 GB'), findsNothing);
    expect(find.text('10 GB'), findsNothing);
    expect(find.text('Server maximum'), findsOneWidget);
  });

  testWidgets('choosing a preset patches its size in bytes', (tester) async {
    final patches = <int>[];
    await tester.pumpWidget(
      _app(_server(serverMax: 2048 * _mib, patches: patches)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('500 MB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('500 MB'));
    await tester.pumpAndSettle();

    expect(patches, [500 * _mib]);
  });

  testWidgets('Server maximum clears the admin limit with 0', (tester) async {
    final patches = <int>[];
    await tester.pumpWidget(
      _app(
        _server(serverMax: 2048 * _mib, current: 100 * _mib, patches: patches),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Server maximum'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Server maximum'));
    await tester.pumpAndSettle();

    expect(patches, [0]);
  });

  testWidgets('a refused change shows a persistent error, not a snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(_server(serverMax: 2048 * _mib, refusePatch: true)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('100 MB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('100 MB'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('fits a phone width without overflowing', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(_server(serverMax: 10240 * _mib)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('10 GB'), findsOneWidget);
  });
}
