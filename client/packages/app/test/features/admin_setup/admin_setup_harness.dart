// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin setup gate over a stand-in shell, wired the way home_shell wires
/// it: a signed-in account with chosen permissions, a recording api whose
/// settings routes keep what is written, and a real router.
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
import 'package:slimm_app/src/features/admin_setup/screens/admin_setup_gate.dart';
import 'package:slimm_app/src/features/first_run/providers/first_run_controller.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_gate.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' hide Message;
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_mic_preview.dart';
import '../first_run/first_run_harness.dart'
    show FakePush, harnessChannel, harnessNow;
import '../voice/voice_snapshot_fixtures.dart' show SnapshotVoiceController;
import 'package:slimm_app/src/providers/push_controller.dart';

const gib = 1024 * 1024 * 1024;

class _Server extends ChosenServer {
  @override
  Uri? build() => Uri.parse('https://space.test');
}

/// What the stand-in server reports for `GET /space/setup`.
class SetupFacts {
  SetupFacts({
    this.claimedByMe = true,
    this.completed = false,
    this.cores = 8,
    this.diskFree = 400 * gib,
    this.diskTotal = 500 * gib,
    this.voice = false,
    this.failComplete = false,
  });

  bool claimedByMe;
  bool completed;
  int cores;
  int diskFree;
  int diskTotal;
  bool voice;
  bool failComplete;

  Map<String, Object?> json() => {
    'claimed_by_me': claimedByMe,
    'completed': completed,
    'capacity': {
      'cores': cores,
      'memory_total_bytes': 16 * gib,
      'memory_limit_bytes': null,
      'disk_free_bytes': diskFree,
      'disk_total_bytes': diskTotal,
      'voice_configured': voice,
      'estimate': {
        'binding': 'connections',
        'connection_limit': 1024,
        'members_min': 340,
        'members_max': 770,
        'voice_min': voice ? 40 : null,
        'voice_max': voice ? 70 : null,
      },
    },
  };
}

class AdminSetupRig {
  AdminSetupRig(this.container, this.requests, this.facts, this.db);
  final ProviderContainer container;
  final List<http.Request> requests;
  final SetupFacts facts;
  final SlimmDatabase db;

  Iterable<http.Request> sent(String method, String path) =>
      requests.where((r) => r.method == method && r.url.path == path);

  Map<String, dynamic> lastBody(String method, String path) =>
      jsonDecode(sent(method, path).last.body) as Map<String, dynamic>;
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// Settings routes that merge a PATCH into what they hold, so a write is visible on the next read.
http.Response _handle(
  http.Request request,
  SetupFacts facts,
  Map<String, Object?> state,
) {
  final path = request.url.path;
  if (path == '/space/setup') return _json(facts.json());
  if (path == '/space/setup/complete') {
    if (facts.failComplete) return _json({'error': 'unavailable'}, 500);
    facts.completed = true;
    return http.Response('', 204);
  }
  if (path == '/version') {
    return _json({
      'name': 'slim-m',
      'version': '0.0.0',
      'protocol': 1,
      'space_name': 'Lamplight',
    });
  }
  if (path == '/me') {
    return _json({
      'id': 'u1',
      'username': 'ada',
      'display_name': 'Ada',
      'created_at': 0,
      'permissions': Perm.manageServer,
    });
  }
  if (path == '/space/retention/preview') return _json({'messages': 0});
  final body = state.putIfAbsent(path, () => _defaults[path] ?? {});
  if (request.method == 'PATCH' || request.method == 'PUT') {
    (body as Map).addAll(jsonDecode(request.body) as Map<String, dynamic>);
  }
  if (path.endsWith('/avatar') || path == '/space/banner') {
    return http.Response('', 404);
  }
  return _json(body as Object);
}

final _defaults = <String, Map<String, Object?>>{
  '/space/settings': {
    'name': 'Lamplight',
    'join_policy': 'invite',
    'totp_policy': 'optional',
    'description': '',
  },
  '/space/join-gate': {
    'enabled': false,
    'rules': '',
    'rules_channel_id': null,
    'joins_paused': false,
  },
  '/space/retention': {'retention_days': 0},
  '/space/attachment-limit': {'max_bytes': 0, 'server_max_bytes': 52428800},
  '/space/screen-share': {'max_height': 2160},
  '/space/media-compression': {
    'enabled': false,
    'extensions': ['jpg', 'png'],
    'default_extensions': ['jpg', 'png'],
    'supported_extensions': ['jpg', 'png'],
    'metadata': 'remove_location',
    'keep_original': false,
  },
};

Future<AdminSetupRig> pumpAdminSetup(
  WidgetTester tester, {
  SetupFacts? setup,
  int permissions = Perm.manageServer,
  Size size = const Size(1280, 800),
  Brightness brightness = Brightness.light,
  Duration accountAge = const Duration(days: 30),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final facts = setup ?? SetupFacts();
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await db.into(db.channels).insert(harnessChannel('general', 'text', 3));
  final requests = <http.Request>[];
  final state = <String, Object?>{};
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
            return _handle(request, facts, state);
          }),
        ),
      ),
      meProvider.overrideWith(
        (ref) => api.Me(
          id: 'u1',
          username: 'ada',
          displayName: 'Ada',
          createdAt: harnessNow.subtract(accountAge).millisecondsSinceEpoch,
          permissions: permissions,
        ),
      ),
      storeProvider.overrideWith((ref) => store),
      databaseProvider.overrideWith((ref) => db),
      chosenServerProvider.overrideWith(_Server.new),
      firstRunClockProvider.overrideWithValue(() => harnessNow),
      pushControllerProvider.overrideWith(
        (ref) => FakePush(PushStatus.noTokenYet),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => SnapshotVoiceController(ref, const VoiceState()),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const FirstRunGate(
          child: AdminSetupGate(child: Scaffold(body: Text('shell'))),
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
  await settleSetup(tester);
  return AdminSetupRig(container, requests, facts, db);
}

/// Real async work (the store, the api mock) runs outside the fake clock.
Future<void> settleSetup(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}
