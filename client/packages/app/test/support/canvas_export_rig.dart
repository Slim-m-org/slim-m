// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rig the "Export canvas" sheet tests share: a signed-in board, a scripted export answer, and the finders.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_export_sheet.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart' show teardownFixture;
import 'async_wait.dart';
import 'fake_api.dart';

const _exportTokens = api.TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);
const _json = {'content-type': 'application/json'};

typedef ExportAnswer =
    FutureOr<http.Response> Function(Map<String, dynamic> body);

http.Response exportedResponse({
  int spared = 0,
  int? left,
  String name = 'minecraft canvas',
}) => http.Response(
  jsonEncode({
    'channel': {
      'id': 'new-channel',
      'name': name,
      'kind': 'canvas',
      'created_at': 1,
    },
    'copied': 3,
    'skipped': 0,
    'cleared': 0,
    'spared': spared,
    'left': ?left,
  }),
  200,
  headers: _json,
);

http.Response refusedResponse(int status, String error, {String? code}) =>
    http.Response(
      jsonEncode({'error': error, 'code': ?code}),
      status,
      headers: _json,
    );

class ExportRig {
  ExportRig(this.tester, this.container, this.router, this.bodies);

  final WidgetTester tester;
  final ProviderContainer container;
  final GoRouter router;
  final List<Map<String, dynamic>> bodies;

  List<ToastMessage> get toasts => container.read(toastsProvider);

  Future<void> open() async {
    await tester.tap(find.text('open'));
    await pumpFrames(tester, frames: 30);
  }

  Future<void> submit(String label) async {
    final before = bodies.length;
    await tester.tap(find.text(label));
    await waitUntil(tester, () => bodies.length > before);
    await pumpFrames(tester, frames: 30);
  }
}

Future<ExportRig> exportRig(
  WidgetTester tester, {
  required ExportAnswer answer,
  int permissions = Perm.manageChannels,
  int channelPermissions = Perm.manageCanvas,
  Map<String, dynamic> source = const {},
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await tester.runAsync(() async {
    await store.upsertChannels([
      api.Channel.fromJson({
        'id': 'board',
        'name': 'minecraft',
        'kind': 'voice',
        'created_at': 0,
        'canvas_enabled': true,
        ...source,
      }),
    ]);
    await store.replaceCategories([
      api.ChannelCategory.fromJson({
        'id': 'gamers',
        'name': 'Gamers',
        'position': 0,
        'created_at': 0,
      }),
    ]);
  });
  final bodies = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: _exportTokens),
      ),
      storeProvider.overrideWith((ref) async => store),
      myPermissionsProvider.overrideWithValue(permissions),
      myChannelPermissionsProvider(
        'board',
      ).overrideWithValue(channelPermissions),
      mockApiOverride((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        bodies.add(body);
        return answer(body);
      }),
    ],
  );
  exportFinishers.add(() => teardownFixture(tester, container, db));
  final router = GoRouter(
    initialLocation: '/start',
    routes: [
      GoRoute(
        path: '/start',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () => showCanvasExportSheet(context, 'board'),
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
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return ExportRig(tester, container, router, bodies);
}

Finder exportButton(String label) =>
    find.byWidgetPredicate((w) => w is AppButton && w.label == label);

AppButton exportButtonWidget(WidgetTester tester, String label) =>
    tester.widget<AppButton>(exportButton(label));

String exportName(WidgetTester tester) => tester
    .widget<AppInput>(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.placeholder == 'Channel name',
      ),
    )
    .controller!
    .text;

bool exportInputEnabled(WidgetTester tester) => tester
    .widget<AppInput>(
      find.byWidgetPredicate(
        (w) => w is AppInput && w.placeholder == 'Channel name',
      ),
    )
    .enabled;

final exportFinishers = <Future<void> Function()>[];

/// A test whose store streams are let go inside it, before the framework checks for stray timers.
void exportTest(String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      for (final finish in exportFinishers) {
        await finish();
      }
      exportFinishers.clear();
    }
  });
}
