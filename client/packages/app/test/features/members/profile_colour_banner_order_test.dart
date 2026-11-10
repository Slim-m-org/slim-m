// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking a colour over a banner image swaps the image out, and the colour
/// goes first so a refused save cannot cost the person their image.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/profile_colour_field.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Server {
  final requests = <String>[];
  bool refuseColour = false;
  bool refuseBannerDelete = false;
  bool bannerSet = true;

  int get meReads => requests.where((r) => r == 'GET /me').length;
}

Future<_Server> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        const json = {'content-type': 'application/json'};
        server.requests.add('${request.method} ${request.url.path}');
        if (request.url.path == '/me/banner') {
          if (server.refuseBannerDelete) return http.Response('{}', 500);
          server.bannerSet = false;
          return http.Response('', 204);
        }
        if (request.method == 'PATCH' && server.refuseColour) {
          return http.Response(
            jsonEncode({'error': 'colour refused'}),
            400,
            headers: json,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'self',
            'username': 'nc1107',
            'display_name': 'Nick',
            'created_at': 0,
            'permissions': 0,
            'profile_color': 0,
            'banner_updated_at': server.bannerSet ? 7 : null,
          }),
          200,
          headers: json,
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
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ProfileColourField(
              imageSet:
                  ref.watch(meProvider).valueOrNull?.bannerUpdatedAt != null,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return server;
}

Future<void> _tapGreen(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Profile colour: Green'));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the colour is saved before the banner image is removed', (
    tester,
  ) async {
    final server = await _pump(tester);
    server.requests.clear();

    await _tapGreen(tester);

    expect(server.requests.take(2), ['PATCH /me', 'DELETE /me/banner']);
  });

  testWidgets('a refused colour leaves the banner image alone', (tester) async {
    final server = await _pump(tester);
    server.refuseColour = true;

    await _tapGreen(tester);

    expect(server.requests, isNot(contains('DELETE /me/banner')));
    expect(server.bannerSet, isTrue);
    expect(
      find.text('Could not save the profile colour. Colour refused.'),
      findsOneWidget,
    );
  });

  testWidgets('a banner that will not go says so and re-reads the profile', (
    tester,
  ) async {
    final server = await _pump(tester);
    server.refuseBannerDelete = true;
    final readsBefore = server.meReads;

    await _tapGreen(tester);

    expect(find.text('Could not remove the banner image.'), findsOneWidget);
    expect(server.meReads, greaterThan(readsBefore));
  });
}
