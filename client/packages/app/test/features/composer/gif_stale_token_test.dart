// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking a gif whose token the server no longer holds.
///
/// The tokens a search hands back live in the server's memory for fifteen
/// minutes and die with any restart - and this deployment restarts on every
/// merge to main. So a picker left open can hold a grid whose every tile is
/// already dead, and tapping one used to report "failed to attach that gif"
/// and leave the same dead grid on screen. Retrying could only fail again.
///
/// The server now says 404 for that specifically, apart from the 503 it says
/// when the provider itself is down, and the picker answers it by reloading
/// rather than reporting - which is what the person would have had to do by
/// hand anyway.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

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

void main() {
  testWidgets('a stale pick reloads the grid instead of reporting it', (
    tester,
  ) async {
    var searches = 0;
    var selects = 0;

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          final path = request.url.path;
          if (path == '/gifs/trending') {
            searches++;
            // A fresh id each round, the way a real re-search mints one.
            return http.Response(
              jsonEncode({
                'results': [_result('tok-$searches')],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (path == '/gifs/select') {
            selects++;
            return http.Response(
              jsonEncode({
                'error':
                    'that gif result has expired; search again '
                    'to refresh them',
              }),
              404,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('unexpected ${request.method} $path', 500);
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: GifPickerBody(onPicked: (_) {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(searches, 1, reason: 'the picker opens on trending');

    // An InkWell, tappable before its preview bytes arrive.
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    expect(selects, 1);
    expect(
      searches,
      2,
      reason: 'the dead grid is replaced rather than left on screen',
    );
    expect(
      find.textContaining('attach that gif'),
      findsNothing,
      reason: 'a reload is the answer, not an error the person cannot act on',
    );
  });
}
