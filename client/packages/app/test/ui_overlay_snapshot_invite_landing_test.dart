// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invite landing card in the join sheet and the admin controls beside its
/// preview, at desktop and phone width.
///
/// Same split as every sibling in this family: the overflow assertion runs
/// everywhere, the PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_app/src/widgets/invite_landing_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 844);

const _json = {'content-type': 'application/json'};

Future<Uint8List> _bannerPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()
    ..shader = ui.Gradient.linear(Offset.zero, const Offset(900, 300), const [
      Color(0xFF2B5FA8),
      Color(0xFF7E57C2),
    ]);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 900, 300), paint);
  final image = await recorder.endRecording().toImage(900, 300);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(loadRealFonts);

  for (final (label, size) in [('desktop', _desktop), ('phone', _phone)]) {
    testWidgets('landing card in the join sheet at $label', (tester) async {
      _view(tester, size);
      final httpClient = MockClient((request) async {
        if (request.url.path == '/version') {
          return http.Response(
            jsonEncode(const {'name': 'Home', 'version': '1', 'protocol': 1}),
            200,
            headers: _json,
          );
        }
        return http.Response(
          jsonEncode(const {
            'usable': true,
            'community': {
              'name': 'Home',
              'member_count': 24,
              'invited_by': 'Nia',
              'uses_remaining': 3,
              'expires_at': 1790000000000,
              'description':
                  'A small home server for friends and family. Game nights '
                  'on Friday, movie nights on Sunday.',
              'banner_updated_at': 5,
            },
          }),
          200,
          headers: _json,
        );
      });
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          probeApiProvider.overrideWithValue(
            (baseUrl) => api.SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: snapshotBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: OnboardingScreen(onServerChosen: (server, invite) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('I have an invite'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://chat.example',
      );
      await tester.enterText(find.byType(TextField).at(1), 'CODE123');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await _finish(tester, 'invite-landing-card-$label');
    });

    testWidgets('admin controls and preview at $label', (tester) async {
      _view(tester, size);
      final png = (await tester.runAsync(_bannerPng))!;
      final httpClient = MockClient((request) async {
        switch (request.url.path) {
          case '/space/settings':
            return http.Response(
              jsonEncode(const {
                'join_policy': 'invite',
                'totp_policy': 'optional',
                'description': 'A small home server for friends and family.',
                'banner_updated_at': 5,
              }),
              200,
              headers: _json,
            );
          case '/space/banner':
            return http.Response.bytes(
              png,
              200,
              headers: const {'content-type': 'image/png'},
            );
          case '/version':
            return http.Response(
              jsonEncode(const {'name': 'Home', 'version': '1', 'protocol': 1}),
              200,
              headers: _json,
            );
          case '/members':
            return http.Response('[]', 200, headers: _json);
        }
        return http.Response('{}', 404, headers: _json);
      });
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          apiProvider.overrideWith(
            (ref) => api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: httpClient,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: snapshotBoundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: const Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(AppSpacing.s16),
                  child: SingleChildScrollView(child: InviteLandingSection()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      await _finish(tester, 'invite-landing-admin-$label');
    });
  }
}
