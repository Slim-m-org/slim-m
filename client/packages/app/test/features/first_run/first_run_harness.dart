// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first-run gate over a stand-in shell, wired the way the app wires it:
/// a due account, a seeded local store, a recording api and a real router.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_gate.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart' hide Message;
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_mic_preview.dart';
import '../voice/voice_snapshot_fixtures.dart' show SnapshotVoiceController;

final harnessNow = DateTime.utc(2026, 10, 18, 12);

class _Server extends ChosenServer {
  @override
  Uri? build() => Uri.parse('https://space.test');
}

class FakePush extends StateNotifier<PushStatus> implements PushController {
  FakePush(super.status);
  var registers = 0;

  @override
  Future<void> register() async => registers++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Channel harnessChannel(String id, String kind, int cursor) => Channel(
  id: id,
  name: id,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class FirstRunRig {
  FirstRunRig(this.container, this.requests, this.push, this.db);
  final ProviderContainer container;
  final List<http.Request> requests;
  final FakePush push;
  final SlimmDatabase db;

  Iterable<http.Request> sent(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path);
}

Future<FirstRunRig> pumpFirstRun(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  Brightness brightness = Brightness.light,
  Duration accountAge = const Duration(minutes: 5),
  Map<String, Object> prefs = const {},
  PushStatus pushStatus = PushStatus.noTokenYet,
  List<Channel>? channels,
  String? inviter,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(prefs);
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  for (final c in channels ?? defaultChannels) {
    await db.into(db.channels).insert(c);
  }
  final requests = <http.Request>[];
  final push = FakePush(pushStatus);
  final container = ProviderContainer(
    overrides: [
      fakeMicPreview(FakeMicSource()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'u1',
            accessToken: 'a',
            refreshToken: 'r',
            accessExpiresAt: 0,
          ),
        ),
      ),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('https://space.test'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add(request);
            return _handle(request);
          }),
        ),
      ),
      meProvider.overrideWith(
        (ref) => api.Me(
          id: 'u1',
          username: 'ada',
          displayName: 'Ada',
          createdAt: harnessNow.subtract(accountAge).millisecondsSinceEpoch,
          permissions: 0,
        ),
      ),
      storeProvider.overrideWith((ref) => store),
      databaseProvider.overrideWith((ref) => db),
      chosenServerProvider.overrideWith(_Server.new),
      firstRunClockProvider.overrideWithValue(() => harnessNow),
      pushControllerProvider.overrideWith((ref) => push),
      voiceControllerProvider.overrideWith(
        (ref) => SnapshotVoiceController(ref, const VoiceState()),
      ),
      if (inviter != null)
        firstRunInviterProvider.overrideWith((ref) => inviter),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            const FirstRunGate(child: Scaffold(body: Text('shell'))),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (_, state) => FirstRunGate(
          child: Scaffold(
            body: Text('channel:${state.pathParameters['channelId']}'),
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: const Key('ui_snapshot_boundary'),
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    ),
  );
  await settle(tester);
  return FirstRunRig(container, requests, push, db);
}

/// Real async work (the store, the api mock) runs outside the fake clock.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final defaultChannels = [
  harnessChannel('quiet', 'text', 3),
  harnessChannel('busy', 'text', 40),
  harnessChannel('lobby', 'voice', 0),
];

http.Response _handle(http.Request request) {
  final path = request.url.path;
  if (path == '/space/settings') {
    return http.Response('{"error":"forbidden"}', 403);
  }
  if (path == '/version') {
    return _json({
      'name': 'slim-m',
      'version': '0.0.0',
      'protocol': 1,
      'space_name': 'Lamplight',
      'space_description': 'A small place for the game night crowd.',
    });
  }
  if (path == '/push/preference') {
    return _json({'preference': 'everything'});
  }
  if (path == '/me') {
    return _json({
      'id': 'u1',
      'username': 'ada',
      'display_name': 'Ada',
      'created_at': 0,
      'permissions': 0,
    });
  }
  if (path.endsWith('/avatar')) return http.Response('', 404);
  return _json(<String, Object>{});
}
