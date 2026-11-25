// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The deployment-wide roster of who has a board open: one read when first needed,
/// patched by frames, read again on reconnect, and cleared when a board is turned off.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_viewers.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../support/fake_api.dart';
import '../../support/fake_blocks.dart';
import '../../support/fake_sync.dart';

const _board = 'board-1';

class _World {
  _World({
    bool capability = true,
    Set<String> blocked = const {},
    Future<void> Function()? gate,
  }) {
    container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        liveEventsProvider.overrideWithValue(frames.stream),
        syncControllerProvider.overrideWith(
          (ref) => StubSyncController(ref, SyncStatus.offline),
        ),
        serverInfoProvider.overrideWith(
          (ref) async => api.Version.fromJson({
            'name': 'slim-m',
            'version': '0.138.0',
            'protocol': 1,
            'capabilities': [if (capability) 'canvas_viewers'],
          }),
        ),
        blocksProvider.overrideWith(
          (ref) => FixedBlocksController(ref, BlocksState(ids: blocked)),
        ),
        mockApiOverride((request) async {
          if (request.url.path != '/presence/canvas-viewers') {
            return http.Response('{}', 200);
          }
          reads++;
          await gate?.call();
          return http.Response(
            jsonEncode({'channels': roster}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      ],
    );
    container.listen(serverInfoProvider, (_, _) {});
  }

  late final ProviderContainer container;
  final frames = StreamController<api.ServerEvent>.broadcast();
  int reads = 0;
  List<Map<String, dynamic>> roster = [
    {
      'channel_id': _board,
      'viewers': [
        {'user_id': 'ada', 'since': 10},
        {'user_id': 'ben', 'since': 20},
      ],
    },
  ];

  CanvasViewersState get state => container.read(canvasViewersProvider);

  List<String> viewers([String channel = _board]) => [
    for (final v in container.read(canvasChannelViewersProvider(channel)))
      v.userId,
  ];

  void goLive() {
    final sync = container.read(syncControllerProvider.notifier);
    (sync as NoopSyncController).report(SyncStatus.live);
  }

  Future<void> dispose() async {
    container.dispose();
    await frames.close();
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('the condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

api.CanvasViewerChanged _frame(String user, bool viewing) =>
    api.CanvasViewerChanged(channelId: _board, userId: user, viewing: viewing);

void main() {
  late _World world;

  Future<_World> started({
    bool capability = true,
    Set<String> blocked = const {},
    Future<void> Function()? gate,
  }) async {
    world = _World(capability: capability, blocked: blocked, gate: gate);
    world.container.read(canvasViewersProvider);
    world.goLive();
    await _until(() => world.state.loaded);
    return world;
  }

  tearDown(() => world.dispose());

  test('reads the roster once however many readers there are', () async {
    await started();
    for (var i = 0; i < 5; i++) {
      world.container.listen(canvasChannelViewersProvider(_board), (_, _) {});
    }
    expect(world.reads, 1);
    expect(world.viewers(), ['ada', 'ben']);
    expect(world.viewers('other'), isEmpty);
  });

  test('frames add and remove viewers in arrival order', () async {
    await started();
    world.frames.add(_frame('cy', true));
    await _until(() => world.viewers().length == 3);
    expect(world.viewers(), ['ada', 'ben', 'cy']);

    world.frames.add(_frame('ada', false));
    await _until(() => world.viewers().length == 2);
    expect(world.viewers(), ['ben', 'cy']);

    world.frames.add(_frame('ben', false));
    world.frames.add(_frame('cy', false));
    await _until(() => world.viewers().isEmpty);
    expect(world.state.byChannel, isEmpty);
  });

  test('reads again when the socket comes back', () async {
    await started();
    world.roster = [];
    final sync = world.container.read(syncControllerProvider.notifier);
    (sync as NoopSyncController).report(SyncStatus.offline);
    sync.report(SyncStatus.live);
    await _until(() => world.reads == 2);
    await _until(() => world.viewers().isEmpty);
  });

  test('a frame that lands while the read is in flight survives it', () async {
    final gate = Completer<void>();
    world = _World(gate: () => gate.future);
    world.container.read(canvasViewersProvider);
    world.goLive();
    await _until(() => world.reads == 1);
    world.frames.add(_frame('cy', true));
    await _until(() => world.state.byChannel.containsKey(_board));
    gate.complete();
    await _until(() => world.state.loaded);
    expect(world.viewers(), ['ada', 'ben', 'cy']);
  });

  test('turning the canvas off clears that board and no other', () async {
    await started();
    world.frames.add(
      const api.CanvasViewerChanged(
        channelId: 'other',
        userId: 'ada',
        viewing: true,
      ),
    );
    await _until(() => world.state.byChannel.containsKey('other'));

    world.frames.add(
      api.ChannelUpdated(
        api.Channel.fromJson({
          'id': _board,
          'name': 'call',
          'kind': 'voice',
          'created_at': 1,
          'canvas_enabled': false,
        }),
      ),
    );
    await _until(() => !world.state.byChannel.containsKey(_board));
    expect(world.state.byChannel.keys, ['other']);
  });

  test('is empty and asks nothing without the capability', () async {
    await started(capability: false);
    expect(world.reads, 0);
    expect(world.viewers(), isEmpty);
  });

  test('a blocked viewer is left out of a reader', () async {
    await started(blocked: {'ben'});
    expect(world.viewers(), ['ada']);
  });
}
