// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The landing preview's banner. The preview page was handed a card built at
/// the tap, and the banner's download only started inside that build, so the
/// page always kept the placeholder, however fast the banner arrived.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/invite_landing_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

const _json = {'content-type': 'application/json'};

class _Server {
  Completer<http.Response> banner = Completer();

  Future<http.Response> handle(http.Request r) async {
    switch ((r.method, r.url.path)) {
      case ('GET', '/space/settings'):
        return http.Response(
          jsonEncode({
            'name': 'Hearth Home',
            'join_policy': 'invite',
            'totp_policy': 'optional',
            'description': 'A small server.',
            'banner_updated_at': 7,
            'icon_updated_at': null,
          }),
          200,
          headers: _json,
        );
      case ('GET', '/space/banner'):
        return banner.future;
      case ('GET', '/members'):
        return http.Response('[]', 200, headers: _json);
      default:
        return http.Response('{}', 404, headers: _json);
    }
  }
}

Future<void> _pump(WidgetTester tester, _Server server) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'user-1',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: InviteLandingSection()),
        ),
      ),
    ),
  );
  await waitUntil(
    tester,
    () => find.text('Space profile').evaluate().isNotEmpty,
  );
}

final _bannerImage = find.byWidgetPredicate(
  (w) => w is Image && w.image is MemoryImage,
);

void main() {
  testWidgets('a banner that lands after the preview opened still shows', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);

    await tester.ensureVisible(find.text('Preview as a visitor'));
    await tester.tap(find.text('Preview as a visitor'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    server.banner.complete(http.Response.bytes(_png, 200));
    await waitUntil(tester, () => _bannerImage.evaluate().isNotEmpty);
    expect(_bannerImage, findsOneWidget);
  });

  testWidgets('a banner that landed before the preview opened shows', (
    tester,
  ) async {
    final server = _Server();
    server.banner.complete(http.Response.bytes(_png, 200));
    await _pump(tester, server);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.ensureVisible(find.text('Preview as a visitor'));
    await tester.tap(find.text('Preview as a visitor'));
    await waitUntil(tester, () => _bannerImage.evaluate().isNotEmpty);
    expect(_bannerImage, findsOneWidget);
  });
}
