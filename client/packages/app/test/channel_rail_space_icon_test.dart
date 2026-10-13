// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The space icon beside the name in the rail header, and the unchanged look
/// when the space has none.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/sync_failure.dart';
import 'package:slimm_app/src/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/space_icon.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Stands in for the real [SyncController]; see `channel_rail_test.dart`'s
/// own copy of this same shape for why overriding `start` is enough.
class _StubSyncController extends SyncController {
  _StubSyncController(super.ref, SyncStatus status) {
    state = status;
  }

  @override
  Future<void> start() async {}
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

ProviderContainer _setup({int? iconUpdatedAt}) => ProviderContainer(
  overrides: [
    syncFailureProvider.overrideWith((ref) => null),
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(
      (ref) => _StubSyncController(ref, SyncStatus.live),
    ),
    hasFailedSinceLiveProvider.overrideWith((ref) => false),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((request) async {
          const json = {'content-type': 'application/json'};
          return switch (request.url.path) {
            '/version' => http.Response(
              jsonEncode({
                'name': 'Home',
                'version': '1',
                'protocol': 1,
                'icon_updated_at': ?iconUpdatedAt,
              }),
              200,
              headers: json,
            ),
            '/space/icon' => http.Response.bytes(_png, 200),
            _ => http.Response('{}', 404, headers: json),
          };
        }),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
);

Future<void> _pumpHeader(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: Column(children: [RailHeader()])),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the connection dot is a badge on the icon bottom-right corner', (
    tester,
  ) async {
    final setup = _setup(iconUpdatedAt: 5);
    addTearDown(setup.dispose);
    await _pumpHeader(tester, setup);

    final icon = tester.getRect(find.byType(SpaceIconFrame));
    final dot = tester.getRect(find.byType(SpaceConnectionDot));
    final name = tester.getRect(find.text('Home'));
    expect(icon.size, const Size.square(AppSizes.icon20));
    expect(dot.center.dx, closeTo(icon.right - 1, 2));
    expect(dot.center.dy, closeTo(icon.bottom - 1, 2));
    expect(dot.size, const Size.square(SpaceConnectionDot.haloedSize));
    expect(find.bySemanticsLabel('Connected to the server'), findsOneWidget);
    expect(name.left, icon.right + AppSpacing.s8);
    expect(icon.center.dy, closeTo(name.center.dy, 1));
  });

  testWidgets('with no icon the header is the name alone', (tester) async {
    final setup = _setup();
    addTearDown(setup.dispose);
    await _pumpHeader(tester, setup);

    expect(find.byType(SpaceIconFrame), findsNothing);
    final dot = tester.getRect(find.byType(SpaceConnectionDot));
    expect(tester.getRect(find.text('Home')).left, closeTo(dot.right + 6, 1));
  });
}
