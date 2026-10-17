// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member's rich-presence activity on the member row and the profile card
/// (decision 0044), at phone and desktop width in both themes.
///
/// The activity arrives through the real `GET /presence` seed path, not a
/// provider override. The overflow and text assertions run everywhere; the
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/activity_card.dart';
import 'package:slimm_app/src/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _art = 'https://i.scdn.co/image/ab67616d0000b273bc2dd68b840b1d4b7c9e5ad9';

/// A cover drawn in code, so the picture shows real art without a network.
Future<MemoryImage> _cover(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const side = 96.0;
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, side, side),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF1DB954), Color(0xFF191414)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(const Rect.fromLTWH(0, 0, side, side)),
    );
    canvas.drawCircle(
      const Offset(48, 48),
      20,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final image = await recorder.endRecording().toImage(96, 96);
    return (await image.toByteData(format: ui.ImageByteFormat.png))!;
  });
  return MemoryImage(bytes!.buffer.asUint8List());
}

api.UserProfile _profile(String id, String name, {String? statusText}) =>
    api.UserProfile(
      id: id,
      username: name.toLowerCase(),
      displayName: name,
      createdAt: 0,
      statusText: statusText,
    );

api.SlimmApi _fakeApi(api.SessionStore session) => api.SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: session,
  httpClient: MockClient((request) async {
    final json = switch (request.url.path) {
      '/me' => {
        'id': 'self',
        'username': 'self',
        'display_name': 'Self',
        'created_at': 0,
        'permissions': 0,
      },
      '/presence' => [
        {
          'user_id': '1',
          'status': 'online',
          'activity': {
            'type': 'listening',
            'title': 'Weightless',
            'subtitle': 'Marconi Union',
            'source': 'Spotify',
            'art_url': _art,
          },
        },
        {
          'user_id': '2',
          'status': 'online',
          'activity': {
            'type': 'listening',
            'title':
                'A very long track title that cannot possibly fit on one line '
                'of a narrow member pane',
            'subtitle': 'An artist with an equally long name',
            'source': 'Mozilla Firefox',
          },
        },
        {'user_id': '3', 'status': 'online'},
      ],
      _ => <String, dynamic>{},
    };
    return http.Response(
      jsonEncode(json),
      200,
      headers: {'content-type': 'application/json'},
    );
  }),
);

Future<void> _pump(
  WidgetTester tester, {
  required Size window,
  required bool drawer,
  required Brightness brightness,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final roster = [
    _profile('1', 'Priya'),
    _profile('2', 'Kess', statusText: 'a typed status'),
    _profile('3', 'Marco', statusText: 'Out until 3'),
  ];
  final cover = await _cover(tester);
  final container = ProviderContainer(
    overrides: [
      activityArtImageProvider.overrideWithValue((_) => cover),
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(StubSyncController.new),
      apiProvider.overrideWith((ref) {
        final client = _fakeApi(ref.watch(sessionProvider));
        ref.onDispose(client.close);
        return client;
      }),
      membersProvider.overrideWith((ref) async => roster),
      channelMembersProvider.overrideWith((ref, _) async => roster),
    ],
  );
  addTearDown(container.dispose);
  final scaffoldKey = GlobalKey<ScaffoldState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
          ),
          home: Scaffold(
            key: scaffoldKey,
            endDrawer: drawer
                ? const Drawer(
                    width: AppMemberPane.width,
                    child: SafeArea(child: AppMemberPane(channelId: 'c1')),
                  )
                : null,
            body: drawer
                ? const Center(child: Text('#general'))
                : const Align(
                    alignment: Alignment.centerRight,
                    child: AppMemberPane(channelId: 'c1'),
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => precacheImage(cover, tester.element(find.byType(Scaffold))),
  );
  if (drawer) scaffoldKey.currentState!.openEndDrawer();
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  final cases = [
    ('phone', const Size(390, 844), true),
    ('desktop', const Size(1280, 800), false),
  ];
  for (final (label, window, drawer) in cases) {
    for (final brightness in Brightness.values) {
      final suffix = '$label-${brightness.name}';

      testWidgets('$suffix: the member row says what they are playing', (
        tester,
      ) async {
        await _pump(
          tester,
          window: window,
          drawer: drawer,
          brightness: brightness,
        );
        expect(find.text('Listening to Weightless - Marconi Union'), findsOne);
        expect(find.textContaining('Listening to A very long'), findsOne);
        expect(find.text('Out until 3'), findsOne);
        expect(find.text('a typed status'), findsNothing);
        await _finish(tester, 'activity-row-$suffix');
      });

      testWidgets('$suffix: the profile card shows cover, source and track', (
        tester,
      ) async {
        await _pump(
          tester,
          window: window,
          drawer: drawer,
          brightness: brightness,
        );
        await tester.tap(find.text('Priya'));
        await tester.pumpAndSettle();
        expect(find.text('LISTENING ON SPOTIFY'), findsOne);
        expect(find.text('Weightless'), findsOne);
        expect(find.text('Marconi Union'), findsOne);
        final cover = tester.getSize(find.byKey(const Key('activity-cover')));
        expect(cover, const Size(AppSpacing.s40, AppSpacing.s40));
        expect(find.byType(Image), findsOne);
        await _finish(tester, 'activity-card-$suffix');
      });

      testWidgets('$suffix: a browser video says so and has no cover', (
        tester,
      ) async {
        await _pump(
          tester,
          window: window,
          drawer: drawer,
          brightness: brightness,
        );
        await tester.tap(find.text('Kess'));
        await tester.pumpAndSettle();
        expect(find.text('LISTENING ON MOZILLA FIREFOX'), findsOne);
        expect(find.byType(Image), findsNothing);
        expect(find.byIcon(AppIcons.listening), findsWidgets);
        await _finish(tester, 'activity-card-browser-$suffix');
      });
    }
  }
}
