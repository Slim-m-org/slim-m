// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `trendingGifsProvider` (`providers/gif_trending.dart`) must survive the
/// picker being dismissed: it used to be plain widget state on
/// `_GifPickerBodyState`, so every open re-fetched trending from the
/// configured provider even though the answer could not have changed since
/// the picker last closed. Counted at the HTTP layer, the same shape
/// `gif_stale_token_test.dart` already uses for its own `/gifs/trending`
/// assertions, so a fetch means a real request left the client rather than
/// a provider-level guess about what "fetched" means.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/providers/gif_trending.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _result(String id) => {
  'id': id,
  'title': 'a cat',
  'width': 100,
  'height': 100,
};

/// Mounts or unmounts [GifPickerBody] on demand - the same shape a sheet
/// being pushed and popped over the composer produces for real, without the
/// route/animation machinery a full `showGifPickerSheet` call would add.
class _ToggleHost extends StatefulWidget {
  const _ToggleHost({super.key});

  @override
  State<_ToggleHost> createState() => _ToggleHostState();
}

class _ToggleHostState extends State<_ToggleHost> {
  bool _open = false;

  void toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) => _open
      ? GifPickerBody(onPicked: (_) {})
      : const Center(child: Text('closed'));
}

void main() {
  testWidgets(
    'opening the picker twice fetches trending once, from the container '
    'that outlives it',
    (tester) async {
      var trendingFetches = 0;

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          apiProvider.overrideWith(
            (ref) => api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                final path = request.url.path;
                if (path == '/gifs/trending') {
                  trendingFetches++;
                  return http.Response(
                    jsonEncode({
                      'results': [_result('tok-1')],
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response('unexpected ${request.method} $path', 500);
              }),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final toggleKey = GlobalKey<_ToggleHostState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: _ToggleHost(key: toggleKey)),
          ),
        ),
      );

      // First open: the picker's own widget state is created fresh here.
      toggleKey.currentState!.toggle();
      await tester.pumpAndSettle();
      expect(trendingFetches, 1, reason: 'the first open fetches trending');

      // Close: _GifPickerBodyState is disposed, the same as a sheet popping.
      toggleKey.currentState!.toggle();
      await tester.pump();
      expect(find.text('closed'), findsOneWidget);

      // Second open: a brand new _GifPickerBodyState, the exact case that used to re-fetch since _trending lived on that dead instance.
      toggleKey.currentState!.toggle();
      await tester.pumpAndSettle();

      expect(find.text('a cat'), findsNothing);
      expect(
        trendingFetches,
        1,
        reason:
            'trendingGifsProvider outlives the picker widget, so a second '
            'open must serve the cached list rather than fetch it again',
      );
    },
  );

  testWidgets(
    'the cache still answers a provider read directly, not only through '
    'the widget',
    (tester) async {
      var trendingFetches = 0;

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          apiProvider.overrideWith(
            (ref) => api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                trendingFetches++;
                return http.Response(
                  jsonEncode({
                    'results': [_result('tok-1')],
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final first = await container.read(trendingGifsProvider.future);
      final second = await container.read(trendingGifsProvider.future);

      expect(first, hasLength(1));
      expect(second, same(first));
      expect(trendingFetches, 1);
    },
  );
}
