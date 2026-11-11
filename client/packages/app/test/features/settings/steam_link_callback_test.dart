// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Steam link's hand-back through the real controller and router: the
/// `slimm://steam-link` link the OS delivers finishes the link with the
/// signed-in account's own session, and a Discord link never reaches Steam's
/// completion route (decision 0115).
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/discord_link_callback.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _code = 'ABCDEFGHJKLMNPQRSTUVWXYZ2';
const _delivered = 'slimm://steam-link?code=$_code';

GoRouter _lightRouter() {
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

class _Rig {
  _Rig(this.container, this.links, this.db, this.completions);

  final ProviderContainer container;
  final StreamController<Uri> links;
  final SlimmDatabase db;
  final List<String> completions;

  String get location => container.read(routerProvider).state.uri.toString();
}

Future<_Rig> _pump(
  WidgetTester tester, {
  bool light = true,
  bool signedIn = true,
}) async {
  final links = StreamController<Uri>.broadcast(sync: true);
  final db = SlimmDatabase(NativeDatabase.memory());
  final completions = <String>[];
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
          httpClient: MockClient((request) async {
            if (request.url.path == '/me/links/steam/complete') {
              completions.add(request.body);
              return http.Response(
                jsonEncode({
                  'provider': 'steam',
                  'username': 'nick_d',
                  'display_name': null,
                  'linked_at': 1,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(jsonEncode({}), 200);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  container
      .read(chosenServerProvider.notifier)
      .restore(Uri.parse('https://chat.example'));
  if (signedIn) container.read(sessionProvider).set(_tokens);
  addTearDown(DeepLinkListener.start(container).dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: container.read(routerProvider),
      ),
    ),
  );
  return _Rig(container, links, db, completions);
}

Future<void> _settle(WidgetTester tester) async {
  await pumpFrames(tester, frames: 4);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await pumpFrames(tester, frames: 4);
}

Future<void> _teardown(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(const SizedBox());
  rig.container.dispose();
  await rig.links.close();
  await tester.pump(const Duration(milliseconds: 1));
  await rig.db.close();
}

void main() {
  test('only a slimm link to the steam-link host is a delivery', () {
    expect(isSteamLinkDelivery(Uri.parse(_delivered)), isTrue);
    expect(
      isSteamLinkDelivery(Uri.parse('slimm://discord-link?code=x')),
      isFalse,
    );
    expect(
      isSteamLinkDelivery(Uri.parse('https://steam-link/?code=x')),
      isFalse,
    );
  });

  testWidgets('a delivered link finishes the link and opens Profile', (
    tester,
  ) async {
    final rig = await _pump(tester);
    rig.container.read(routerProvider).go(Routes.channels);
    await _settle(tester);

    rig.links.add(Uri.parse(_delivered));
    await _settle(tester);

    expect(rig.completions.map(jsonDecode), [
      {'code': _code},
    ]);
    expect(rig.location, Routes.personalSettingsPane('profile'));
    await _teardown(tester, rig);
  });

  testWidgets('signed out, or without a code, nothing is sent', (tester) async {
    final rig = await _pump(tester, signedIn: false);
    rig.links.add(Uri.parse(_delivered));
    await _settle(tester);
    expect(rig.completions, isEmpty);
    await _teardown(tester, rig);

    final signedIn = await _pump(tester);
    signedIn.links.add(Uri.parse('slimm://steam-link'));
    await _settle(tester);
    expect(signedIn.completions, isEmpty);
    await _teardown(tester, signedIn);
  });
}
