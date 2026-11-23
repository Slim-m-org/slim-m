// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module tile's held frame: a live frame is never replaced by an older
/// read, a reconnect reads the frames again, and a press that outlives its
/// tiles ends quietly.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_module_tiles.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  final events = StreamController<api.ServerEvent>.broadcast();
  var stored = 'old';
  Completer<void>? sceneGate;
  Completer<void>? pressGate;
  var sceneReads = 0;

  late final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events.stream),
      syncControllerProvider.overrideWith(NoopSyncController.new),
      mockApiOverride((request) async {
        if (request.method == 'POST') {
          await pressGate?.future;
          return _json({'ok': true, 'output': 'pressed'});
        }
        sceneReads++;
        await sceneGate?.future;
        return _json({'object_id': 'o1', 'output': stored, 'ran_at': 1});
      }),
    ],
  );

  late final sub = container.listen(canvasTileFramesProvider('c1'), (_, _) {});

  CanvasTileFrames get frames =>
      container.read(canvasTileFramesProvider('c1').notifier);
  String? get output => sub.read()['o1']?.output;
  NoopSyncController get sync =>
      container.read(syncControllerProvider.notifier) as NoopSyncController;

  void live(String output) => events.add(
    api.CanvasTileSceneChanged(
      channelId: 'c1',
      objectId: 'o1',
      output: output,
      ranAt: 1,
    ),
  );
}

Future<_Rig> _open() async {
  final rig = _Rig();
  addTearDown(rig.events.close);
  addTearDown(rig.container.dispose);
  rig.sub;
  rig.sync;
  return rig;
}

void main() {
  test(
    'a live frame is not replaced by the read that left before it',
    () async {
      final rig = await _open();
      rig.sceneGate = Completer<void>();
      final ensured = rig.frames.ensure('o1');
      await pumpEventQueue();

      rig.live('live');
      await pumpEventQueue();
      rig.sceneGate!.complete();
      await ensured;

      expect(rig.output, 'live');
    },
  );

  test('a reconnect reads the held frames again', () async {
    final rig = await _open();
    await rig.frames.ensure('o1');
    expect(rig.output, 'old');

    rig.stored = 'new';
    rig.sync.report(SyncStatus.offline);
    rig.sync.report(SyncStatus.live);
    await pumpEventQueue();

    expect(rig.output, 'new');
  });

  test('a press that outlives its tiles ends without an error', () async {
    final rig = await _open();
    await rig.frames.ensure('o1');
    rig.pressGate = Completer<void>();
    final pressed = rig.frames.press('o1', 'go');
    await pumpEventQueue();

    rig.sub.close();
    await pumpEventQueue();
    rig.pressGate!.complete();

    expect((await pressed).ok, isTrue);
  });
}
