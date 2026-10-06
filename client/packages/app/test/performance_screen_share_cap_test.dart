// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The screen-share resolution ceiling control on the Space performance
/// screen: it shows the current ceiling, patches a new one, and states the
/// bandwidth consequence of the chosen ceiling. Its own file for the same
/// reason `performance_canvas_cap_test.dart` is: the two share a screen but
/// not a file, and `performance_screen_test.dart` is at its file-size
/// ceiling.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/performance_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _containerFor(MockClient client) => ProviderContainer(
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
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: const Scaffold(body: PerformanceScreen()),
  ),
);

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

MockClient _clientWith({
  required int Function() maxHeight,
  void Function(int)? onPatch,
}) => MockClient((request) async {
  if (request.url.path == '/space/retention') {
    return _json({'retention_days': 0});
  }
  if (request.url.path == '/space/canvas-cap') {
    return _json({'object_cap': 20000});
  }
  if (request.url.path == '/space/screen-share') {
    if (request.method == 'PATCH') {
      final next = (jsonDecode(request.body) as Map)['max_height'] as int;
      onPatch?.call(next);
    }
    return _json({'max_height': maxHeight()});
  }
  return _json({'enabled': false});
});

void main() {
  testWidgets(
    'the screen share cap section shows the current ceiling and patches a '
    'new one',
    (tester) async {
      var maxHeight = 2160;
      final patchedHeights = <int>[];
      final client = _clientWith(
        maxHeight: () => maxHeight,
        onPatch: (h) {
          maxHeight = h;
          patchedHeights.add(h);
        },
      );
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      expect(find.text('Screen share quality'), findsOneWidget);

      // The section sits below the fold in the test viewport; scroll first.
      await tester.ensureVisible(find.text('720p'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();

      expect(patchedHeights, [720]);
    },
  );

  testWidgets(
    'states the real per-tier bitrate ceiling as the bandwidth consequence, '
    'and updates it when the ceiling changes',
    (tester) async {
      var maxHeight = 2160;
      final client = _clientWith(
        maxHeight: () => maxHeight,
        onPatch: (h) => maxHeight = h,
      );
      final container = _containerFor(client);
      addTearDown(container.dispose);

      await tester.pumpWidget(_app(container));
      await tester.pumpAndSettle();

      // 2160 ("Source") matches no tier's own height, so the copy says so rather than inventing a bitrate.
      expect(find.textContaining('already tops out at 1440p'), findsOneWidget);

      await tester.ensureVisible(find.text('720p'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pumpAndSettle();

      // 720p matches ScreenShareQuality.smooth's real 2.5 Mbps ceiling.
      expect(find.textContaining('2.5 Mbps'), findsOneWidget);
      expect(find.textContaining('1280x720'), findsOneWidget);
    },
  );

  Future<AppSegmentedControl> pumpCeiling(
    WidgetTester tester,
    MockClient client,
  ) async {
    final container = _containerFor(client);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('720p'));
    await tester.pumpAndSettle();
    return tester.widget<AppSegmentedControl>(
      find.byWidgetPredicate(
        (w) =>
            w is AppSegmentedControl &&
            w.semanticLabel == 'Screen share resolution ceiling',
      ),
    );
  }

  testWidgets('a ceiling between the presets gets its own selected segment', (
    tester,
  ) async {
    final control = await pumpCeiling(
      tester,
      _clientWith(maxHeight: () => 900),
    );

    expect(control.options[control.selectedIndex].label, '900p');
    expect(find.textContaining('No cap'), findsNothing);
    expect(find.textContaining('capped at 900p'), findsOneWidget);
  });

  testWidgets(
    'a ceiling that failed to load selects nothing and claims no cap',
    (tester) async {
      final client = MockClient((request) async {
        if (request.url.path == '/space/screen-share') {
          return http.Response('{}', 500);
        }
        return _json({
          'retention_days': 0,
          'object_cap': 20000,
          'enabled': false,
        });
      });

      final control = await pumpCeiling(tester, client);

      expect(control.selectedIndex, -1);
      expect(find.textContaining('No cap'), findsNothing);
    },
  );
}
