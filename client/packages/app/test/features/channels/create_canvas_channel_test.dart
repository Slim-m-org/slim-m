// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The create sheet's Canvas kind and the per-kind toggles: Canvas only on a server that knows canvas channels, Lobby and Canvas for voice, Voice call for canvas, Private last.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/canvas_channels_supported.dart';
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

const _json = {'content-type': 'application/json'};

Finder _toggle(String label) =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == label);

Finder _kindLabel(String kind) =>
    find.descendant(of: _kindControl(), matching: find.text(kind));

Finder _kindControl() => find.bySemanticsLabel('Channel kind');

class _Opened {
  _Opened(this.router, this.bodies);

  final GoRouter router;
  final List<Map<String, dynamic>> bodies;
}

Future<_Opened> _open(
  WidgetTester tester, {
  required bool canvasChannels,
  String initialKind = 'text',
  int permissions = 0,
  List<Override> extra = const [],
}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final bodies = <Map<String, dynamic>>[];
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(
        path: '/start',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () =>
                showCreateChannelSheet(context, initialKind: initialKind),
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (_, __) => const Placeholder(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        myPermissionsProvider.overrideWithValue(permissions),
        ...extra,
        mockApiOverride((request) async {
          if (request.url.path == '/version') {
            return http.Response(
              jsonEncode({
                'name': 's',
                'version': '1',
                'protocol': 1,
                'canvas_channels': canvasChannels,
              }),
              200,
              headers: _json,
            );
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          return http.Response(
            jsonEncode({
              'id': 'new-channel',
              'name': body['name'],
              'kind': body['kind'],
              'created_at': 0,
            }),
            200,
            headers: _json,
          );
        }),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open'));
  await pumpFrames(tester, frames: 30);
  await tester.enterText(
    find.byWidgetPredicate(
      (w) => w is AppInput && w.placeholder == 'Channel name',
    ),
    'designs',
  );
  await tester.pump();
  return _Opened(router, bodies);
}

Future<void> _pick(WidgetTester tester, String kind) async {
  await tester.tap(
    find.descendant(of: _kindControl(), matching: find.text(kind)),
  );
  await pumpFrames(tester, frames: 30);
}

Future<Map<String, dynamic>> _submit(WidgetTester tester, _Opened o) async {
  final before = o.bodies.length;
  await tester.tap(find.text('Create channel'));
  await waitUntil(tester, () => o.bodies.length > before);
  await pumpFrames(tester, frames: 30);
  return o.bodies.last;
}

Future<void> _release(WidgetTester tester) async {
  // The open sheet watches the store's categories, a drift stream that only lets go once unmounted.
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
}

void main() {
  testWidgets('an older server offers two kinds and no canvas', (tester) async {
    await _open(tester, canvasChannels: false);
    await pumpFrames(tester, frames: 30);

    expect(_kindLabel('Text'), findsOneWidget);
    expect(_kindLabel('Voice'), findsOneWidget);
    expect(_kindLabel('Canvas'), findsNothing);
    await _pick(tester, 'Voice');
    expect(find.text('Lobby'), findsOneWidget);
    expect(find.text('Canvas'), findsNothing, reason: 'no canvas row either');
    await _release(tester);
  });

  testWidgets('a canvas-aware server offers Text, Voice and Canvas', (
    tester,
  ) async {
    await _open(tester, canvasChannels: true);
    await pumpFrames(tester, frames: 30);

    final xs = [
      for (final k in ['Text', 'Voice', 'Canvas'])
        tester.getCenter(_kindLabel(k)).dx,
    ];
    expect(xs, orderedEquals([...xs]..sort()));
    await _release(tester);
  });

  testWidgets('each kind has its caption and its toggles, Private last', (
    tester,
  ) async {
    await _open(tester, canvasChannels: true, permissions: Perm.manageRoles);
    await pumpFrames(tester, frames: 30);

    expect(find.textContaining('People post messages'), findsOneWidget);
    expect(find.text('Lobby'), findsNothing);
    expect(find.text('Voice call'), findsNothing);

    await _pick(tester, 'Voice');
    expect(find.textContaining('People join a live call'), findsOneWidget);
    final lobby = tester.getTopLeft(find.text('Lobby')).dy;
    final canvas = tester.getTopLeft(find.text('Canvas').last).dy;
    final privateRow = tester.getTopLeft(find.text('Private')).dy;
    expect(lobby, lessThan(canvas));
    expect(canvas, lessThan(privateRow));
    expect(find.text('Adds a shared board to this channel.'), findsOneWidget);
    expect(find.text('Voice call'), findsNothing);

    await _pick(tester, 'Canvas');
    expect(
      find.text('A shared board to work on together, with chat to the side.'),
      findsOneWidget,
    );
    expect(find.text('Lobby'), findsNothing, reason: 'a canvas is no lobby');
    expect(find.text('Adds a shared board to this channel.'), findsNothing);
    expect(find.text('Lets people talk while they work.'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Voice call')).dy,
      lessThan(tester.getTopLeft(find.text('Private')).dy),
    );
    await _release(tester);
  });

  testWidgets('switching kind keeps the name and Private, resets the toggles', (
    tester,
  ) async {
    final o = await _open(
      tester,
      canvasChannels: true,
      permissions: Perm.manageRoles,
    );
    await tester.tap(_toggle('Make this channel private'));
    await pumpFrames(tester, frames: 30);
    await _pick(tester, 'Voice');
    await tester.tap(_toggle('Add a canvas to this channel'));
    await tester.tap(_toggle('Make this a lobby'));
    await pumpFrames(tester, frames: 30);
    await _pick(tester, 'Canvas');
    await tester.tap(_toggle('Let people call in this channel'));
    await pumpFrames(tester, frames: 30);
    await _pick(tester, 'Voice');

    expect(
      tester.widget<AppToggle>(_toggle('Add a canvas to this channel')).value,
      isFalse,
    );
    expect(
      tester.widget<AppToggle>(_toggle('Make this a lobby')).value,
      isFalse,
    );
    expect(
      tester.widget<AppToggle>(_toggle('Make this channel private')).value,
      isTrue,
    );
    await _pick(tester, 'Canvas');
    expect(
      tester
          .widget<AppToggle>(_toggle('Let people call in this channel'))
          .value,
      isFalse,
    );
    expect(find.text('designs'), findsOneWidget, reason: 'the name stays');
    expect(o.bodies, isEmpty);
    await _release(tester);
  });

  testWidgets('voice sends canvas_enabled, off by default and on when set', (
    tester,
  ) async {
    final o = await _open(tester, canvasChannels: true);
    await _pick(tester, 'Voice');
    final off = await _submit(tester, o);
    expect(off['kind'], 'voice');
    expect(off['canvas_enabled'], isFalse);
    expect(off.containsKey('voice_enabled'), isFalse);
    await _release(tester);

    final again = await _open(tester, canvasChannels: true);
    await _pick(tester, 'Voice');
    await tester.tap(_toggle('Add a canvas to this channel'));
    await pumpFrames(tester, frames: 30);
    expect((await _submit(tester, again))['canvas_enabled'], isTrue);
    await _release(tester);
  });

  testWidgets('canvas sends voice_enabled, off by default and on when set', (
    tester,
  ) async {
    final o = await _open(tester, canvasChannels: true);
    await _pick(tester, 'Canvas');
    final off = await _submit(tester, o);
    expect(off['kind'], 'canvas');
    expect(off['voice_enabled'], isFalse);
    expect(off.containsKey('canvas_enabled'), isFalse);
    await _release(tester);

    final again = await _open(tester, canvasChannels: true);
    await _pick(tester, 'Canvas');
    await tester.tap(_toggle('Let people call in this channel'));
    await pumpFrames(tester, frames: 30);
    expect((await _submit(tester, again))['voice_enabled'], isTrue);
    await _release(tester);
  });

  testWidgets('a text channel sends neither flag, and an older server none', (
    tester,
  ) async {
    final text = await _open(tester, canvasChannels: true);
    final body = await _submit(tester, text);
    expect(body.containsKey('canvas_enabled'), isFalse);
    expect(body.containsKey('voice_enabled'), isFalse);
    await _release(tester);

    final old = await _open(tester, canvasChannels: false);
    await _pick(tester, 'Voice');
    final voice = await _submit(tester, old);
    expect(voice.containsKey('canvas_enabled'), isFalse);
    await _release(tester);
  });

  testWidgets(
    'a new canvas channel opens, a new text channel opens, voice stays',
    (tester) async {
      final canvas = await _open(tester, canvasChannels: true);
      await _pick(tester, 'Canvas');
      await _submit(tester, canvas);
      expect(
        canvas.router.routerDelegate.currentConfiguration.uri.path,
        Routes.channel('new-channel'),
      );
      await _release(tester);

      final voice = await _open(tester, canvasChannels: true);
      await _pick(tester, 'Voice');
      await _submit(tester, voice);
      expect(
        voice.router.routerDelegate.currentConfiguration.uri.path,
        '/start',
      );
      await _release(tester);
    },
  );

  testWidgets(
    'the sheet starts on Canvas when asked, and on Text without the kind',
    (tester) async {
      await _open(tester, canvasChannels: true, initialKind: 'canvas');
      await pumpFrames(tester, frames: 30);
      expect(find.text('Lets people talk while they work.'), findsOneWidget);
      await _release(tester);

      await _open(tester, canvasChannels: false, initialKind: 'canvas');
      await pumpFrames(tester, frames: 30);
      expect(find.textContaining('People post messages'), findsOneWidget);
      await _release(tester);
    },
  );

  testWidgets('a canvas pick that loses its server support creates nothing', (
    tester,
  ) async {
    final supported = StateProvider<bool>((ref) => true);
    final o = await _open(
      tester,
      canvasChannels: true,
      extra: [
        canvasChannelsSupportedProvider.overrideWith(
          (ref) => ref.watch(supported),
        ),
      ],
    );
    await _pick(tester, 'Canvas');
    ProviderScope.containerOf(
      tester.element(find.text('Create channel')),
    ).read(supported.notifier).state = false;
    await tester.tap(find.text('Create channel'));
    await pumpFrames(tester, frames: 30);

    expect(o.bodies, isEmpty);
    expect(
      find.text("This server doesn't support canvas channels."),
      findsOneWidget,
    );
    await _release(tester);
  });
}
