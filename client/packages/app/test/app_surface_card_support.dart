// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Mounts the real [AppSurfaceView] with a module's scene as its launch answer.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/modules/widgets/app_surface_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';

Future<void> pumpAppCard(
  WidgetTester tester, {
  required Map<String, Object?> scene,
  required double windowWidth,
  Key? boundary,
  String title = 'word-guess',
}) async {
  tester.view.physicalSize = Size(windowWidth, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'self',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      mockApiOverride(
        (_) async => http.Response(
          jsonEncode({'ok': true, 'output': jsonEncode(scene)}),
          200,
          headers: {'content-type': 'application/json'},
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
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            // A message column: the card is offered the whole row width.
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppSurfaceView(
                    messageId: 'm1',
                    surface: api.AppSurface(moduleId: title, command: 'play'),
                    title: title,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
