// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Provider overrides that answer the app's API from memory, and one pump
/// helper that mounts a widget under a container with those overrides.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

/// Overrides [apiProvider] with an api answered by [handler], on the app's session.
Override mockApiOverride(MockClientHandler handler) =>
    apiProvider.overrideWith((ref) {
      final api = testApi(handler, session: ref.watch(sessionProvider));
      ref.onDispose(api.close);
      return api;
    });

/// Overrides [apiProvider] with an api served by the fake [server].
Override fakeServerOverride(FakeSlimmServer server) =>
    apiProvider.overrideWith((ref) {
      final api = server.api(session: ref.watch(sessionProvider));
      ref.onDispose(api.close);
      return api;
    });

/// Mounts [child] under a fresh container, in the light theme, and returns it.
Future<ProviderContainer> pumpInApp(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  final container = ProviderContainer(overrides: overrides);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return container;
}
