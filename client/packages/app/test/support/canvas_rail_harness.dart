// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared rig for the canvas channel rail row tests: the server's answers, the rail on a router and the channel makers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'async_wait.dart';
import 'fake_api.dart';
import 'fake_sync.dart';
import '../features/voice/voice_controller_harness.dart';

const railTokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel canvasChannel(
  String id,
  String name, {
  bool call = false,
  int cursor = 0,
  int lastReadSeq = 0,
  int mentionedSeq = 0,
}) => Channel(
  id: id,
  name: name,
  kind: 'canvas',
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: lastReadSeq,
  mentionedSeq: mentionedSeq,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  voiceEnabled: call,
  canvasEnabled: true,
  categoryId: 'cat1',
);

Channel voiceChannel(String id, String name) => Channel(
  id: id,
  name: name,
  kind: 'voice',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: 'cat1',
);

/// The server's answers, and a count of each read the rail makes.
class RailWire {
  RailWire({this.viewers = const {}, this.call = const {}});

  /// Channel id to the user ids with its board open.
  final Map<String, List<String>> viewers;

  /// Channel id to the people in its call.
  final Map<String, List<String>> call;
  final reads = <String, int>{};

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    reads.update(path, (n) => n + 1, ifAbsent: () => 1);
    if (path == '/presence/canvas-viewers') {
      return _json({
        'channels': [
          for (final e in viewers.entries)
            {
              'channel_id': e.key,
              'viewers': [
                for (var i = 0; i < e.value.length; i++)
                  {'user_id': e.value[i], 'since': i + 1},
              ],
            },
        ],
      });
    }
    final roster = RegExp(r'^/channels/([^/]+)/voice/roster$').firstMatch(path);
    if (roster != null) {
      return _json({
        'participants': [
          for (final id in call[roster.group(1)] ?? const <String>[])
            {'user_id': id, 'display_name': id},
        ],
      });
    }
    return http.Response('', 404);
  }

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
}

class RailHarness {
  RailHarness(this.tester, this.wire);

  final WidgetTester tester;
  final RailWire wire;
  late final GoRouter router;
  final frames = StreamController<api.ServerEvent>.broadcast();
  RecordingVoiceController? voice;

  Future<void> show(
    List<Channel> channels, {
    required double width,
    double railWidth = 240,
    bool canManage = true,
    String? selectedId,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(frames.close);
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width < 600 ? width : railWidth,
                child: ChannelCategorySections(
                  channels: channels,
                  categories: const [
                    ChannelCategoryRow(id: 'cat1', name: 'Design', position: 0),
                  ],
                  selectedId: selectedId,
                  canManage: canManage,
                  onReorder: (_) {},
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/channels/:id',
          builder: (_, state) => Text('board ${state.pathParameters['id']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWithValue(
            api.SessionStore(tokens: railTokens),
          ),
          mockApiOverride(wire.answer),
          liveEventsProvider.overrideWithValue(frames.stream),
          syncControllerProvider.overrideWith(
            (ref) => StubSyncController(ref, SyncStatus.live),
          ),
          serverInfoProvider.overrideWith(
            (ref) async => api.Version.fromJson({
              'name': 'slim-m',
              'version': '0.138.0',
              'protocol': 1,
              'capabilities': ['canvas_viewers'],
            }),
          ),
          voiceControllerProvider.overrideWith((ref) {
            return voice = RecordingVoiceController(ref);
          }),
        ],
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    );
    if (channels.any((c) => c.isCanvasChannel)) {
      await waitUntil(
        tester,
        () => wire.reads['/presence/canvas-viewers'] != null,
      );
    }
    await pumpFrames(tester);
  }

  Finder row(String id) => find.byKey(ValueKey('canvas-row-$id'));
  Finder avatar(String userId) => find.byKey(ValueKey(userId));
  Rect rect(Finder f) => tester.getRect(f);
}

Future<void> hoverRow(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(tester.getCenter(target));
  await pumpFrames(tester);
}
