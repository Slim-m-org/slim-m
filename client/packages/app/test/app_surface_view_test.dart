// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AppSurfaceView] launches its module's command on mount and every step
/// through the message-scoped, shared code-run route, never the ephemeral
/// per-caller one - so a launched app is the same evolving surface for everyone
/// viewing the message, per docs/decisions/0021's module-agnostic principle.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/app_surface_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _scene(String state) =>
    '{"\$slim":"scene/1","width":3,"height":3,'
    '"ops":[{"op":"cells","cols":3,"rows":3,"data":"000010000",'
    '"palette":["sunken","accent"],"tap":"toggle"}],'
    '"controls":["step"],"state":"$state","live":true}';

void main() {
  testWidgets(
    'launches on mount and steps through the shared message-scoped route',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final paths = <String>[];

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(events.stream),
          mockApiOverride((request) async {
            paths.add(request.url.path);
            // The shared render comes from the broadcast (extras), so feed one.
            events.add(
              api.CodeRunChanged(
                channelId: 'c1',
                messageId: 'm1',
                run: api.CodeRun(
                  blockIndex: 0,
                  moduleId: 'game-of-life',
                  command: 'life',
                  ok: true,
                  output: _scene('s${paths.length}'),
                  ranBy: 'u1',
                  ranAt: 1700000000000 + paths.length,
                ),
              ),
            );
            return http.Response(
              jsonEncode({'ok': true, 'output': _scene('s${paths.length}')}),
              200,
              headers: {'content-type': 'application/json'},
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
            home: const Scaffold(
              body: AppSurfaceView(
                messageId: 'm1',
                surface: api.AppSurface(
                  moduleId: 'game-of-life',
                  command: 'life',
                ),
                title: 'game-of-life',
              ),
            ),
          ),
        ),
      );
      // The post-frame auto-run needs a settle to fire and its broadcast to land.
      await tester.pumpAndSettle();

      expect(
        paths,
        isNotEmpty,
        reason: 'it should launch itself on mount without a tap',
      );
      expect(find.bySemanticsLabel('Step forward'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Step forward'));
      await tester.pumpAndSettle();

      expect(paths.length, greaterThanOrEqualTo(2));
      expect(paths, everyElement('/messages/m1/blocks/0/run'));
      expect(
        paths.any((p) => p.contains('/commands/')),
        isFalse,
        reason: 'a launch or step must not hit the ephemeral run endpoint',
      );
    },
  );

  group('a launch that cannot complete', () {
    Future<(ProviderContainer, List<String>)> pumpRefused(
      WidgetTester tester, {
      required int status,
      Widget Function()? home,
    }) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final paths = <String>[];
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
          mockApiOverride((request) async {
            paths.add(request.url.path);
            return http.Response(
              jsonEncode({'error': 'insufficient permissions'}),
              status,
              headers: {'content-type': 'application/json'},
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
            home: Scaffold(body: home?.call() ?? _surface(const ValueKey('a'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (container, paths);
    }

    testWidgets('says so with a Retry instead of spinning', (tester) async {
      await pumpRefused(tester, status: 403);

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('asks once over a minute, however often it rebuilds', (
      tester,
    ) async {
      final (_, paths) = await pumpRefused(tester, status: 429);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(paths, hasLength(1));
    });

    testWidgets('a remount of the same message does not ask again', (
      tester,
    ) async {
      final (container, paths) = await pumpRefused(tester, status: 403);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: _surface(const ValueKey('b'))),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(paths, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Retry asks again, and only then', (tester) async {
      final (_, paths) = await pumpRefused(tester, status: 403);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(paths, hasLength(2));
      expect(find.byType(AppErrorState), findsOneWidget);
    });
  });

  testWidgets('a launch that answered shows its frame without the broadcast', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        mockApiOverride(
          (_) async => http.Response(
            jsonEncode({'ok': true, 'output': _scene('s1')}),
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
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: _surface(const ValueKey('a'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Step forward'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

Widget _surface(Key key) => AppSurfaceView(
  key: key,
  messageId: 'm1',
  surface: const api.AppSurface(moduleId: 'music-box', command: 'sequence'),
  title: 'music-box',
);
