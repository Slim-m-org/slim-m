// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A preview in an unfocused window must hold its frame rather than animate
/// unseen; the grid itself is already lazy, so only the built tiles count.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _gifBytes = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);

Future<void> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/gifs/trending') {
          return http.Response(
            jsonEncode({
              'results': [
                for (var i = 0; i < 40; i++)
                  {'id': 'tok-$i', 'title': 'cat $i', 'width': 1, 'height': 1},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(
          _gifBytes,
          200,
          headers: {'content-type': 'image/gif'},
        );
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
}

List<bool> _ticking(WidgetTester tester) => [
  for (final e in find.byType(Image).evaluate()) TickerMode.valuesOf(e).enabled,
];

void main() {
  testWidgets(
    'previews animate in a focused window and hold in an unfocused one',
    (tester) async {
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      await _pump(tester);

      final ticking = _ticking(tester);
      expect(
        ticking.length,
        greaterThan(10),
        reason: 'many previews are built',
      );
      expect(ticking.every((t) => t), isTrue, reason: 'in view: animates');

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(_ticking(tester).any((t) => t), isFalse);
    },
  );
}
