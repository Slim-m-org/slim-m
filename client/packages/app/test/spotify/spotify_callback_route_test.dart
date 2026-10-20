// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify redirect through the real router (decision 0056): the OS hands
/// the URL to Flutter's route information as well as to the deep-link
/// stream, and the person must stay on Settings, or be brought to it when the
/// app was not showing it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _callback = 'slimm://spotify-callback?code=c&state=s';

/// Stand-ins for the two screens that matter here, so the shell and its
/// plugins stay out of a test about where a link lands.
GoRouter _lightRouter() {
  // The app's router sets this too, so a pushed Settings shows in the address.
  GoRouter.optionURLReflectsImperativeAPIs = true;
  return GoRouter(
    initialLocation: Routes.channels,
    routes: [
      GoRoute(path: Routes.channels, builder: (_, _) => const Text('channels')),
      GoRoute(
        path: Routes.personalSettings,
        builder: (_, _) => const Text('settings'),
      ),
    ],
  );
}

Future<(ProviderContainer, StreamController<Uri>, SlimmDatabase)> _pump(
  WidgetTester tester, {
  bool light = true,
}) async {
  final links = StreamController<Uri>.broadcast(sync: true);
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      databaseProvider.overrideWith((ref) => db),
      deepLinkUrisProvider.overrideWithValue(links.stream),
      if (light) routerProvider.overrideWith((ref) => _lightRouter()),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(
            (_) async => http.Response(jsonEncode({}), 200),
          ),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  container
      .read(chosenServerProvider.notifier)
      .restore(Uri.parse('https://chat.example'));
  container.read(sessionProvider).set(_tokens);
  container.read(deepLinkControllerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: container.read(routerProvider),
      ),
    ),
  );
  return (container, links, db);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  StreamController<Uri> links,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await links.close();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

String _location(ProviderContainer container) =>
    container.read(routerProvider).state.uri.toString();

void main() {
  testWidgets('the redirect Flutter also receives never leaves Settings', (
    tester,
  ) async {
    final (container, links, db) = await _pump(tester, light: false);
    container.read(routerProvider).go(Routes.personalSettings);
    await tester.pump();
    await tester.pump();
    expect(_location(container), Routes.personalSettings);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/navigation',
      const JSONMethodCodec().encodeMethodCall(
        const MethodCall('pushRouteInformation', {'location': _callback}),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.pump();

    expect(_location(container), Routes.personalSettings);
    await _teardown(tester, container, links, db);
  });

  testWidgets('a redirect with Settings closed opens the Profile pane', (
    tester,
  ) async {
    final (container, links, db) = await _pump(tester);
    container.read(routerProvider).go(Routes.channels);
    await _settle(tester);

    links.add(Uri.parse(_callback));
    await _settle(tester);

    expect(_location(container), Routes.personalSettingsPane('profile'));
    await _teardown(tester, container, links, db);
  });

  testWidgets('a redirect with Settings open stays where it is', (
    tester,
  ) async {
    final (container, links, db) = await _pump(tester);
    container.read(routerProvider).go(Routes.personalSettings);
    await _settle(tester);

    links.add(Uri.parse(_callback));
    await _settle(tester);

    expect(_location(container), Routes.personalSettings);
    await _teardown(tester, container, links, db);
  });
}
