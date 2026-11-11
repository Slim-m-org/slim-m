// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas keeps its camera when the pane is swapped for the call and back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' show VoiceRosterParticipant;
import 'package:http/testing.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/fake_sync.dart';
import '../canvas/canvas_pane_harness.dart';
import 'voice_controller_harness.dart';

VoiceParticipant _person(int i, {bool sharing = false}) => VoiceParticipant(
  identity: 'p$i',
  name: 'p$i',
  isLocal: i == 0,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: sharing,
);

http.Client _api() {
  return MockClient((request) async {
    final path = request.url.path;
    if (path.contains('/voice/')) {
      return voiceApi().send(request).then(http.Response.fromStream);
    }
    if (path.endsWith('/me')) {
      return jsonResponse({
        'id': 'user-1',
        'username': 'me',
        'display_name': 'Me',
        'created_at': 0,
        'permissions': 0,
      });
    }
    if (path.endsWith('/permissions')) return jsonResponse({'permissions': 0});
    if (path.endsWith('/canvas/ops')) {
      return jsonResponse({
        'ops': <Object>[],
        'latest_seq': 0,
        'has_more': false,
        'reset': false,
      });
    }
    if (path.endsWith('/canvas/objects')) {
      return jsonResponse({
        'objects': <Object>[],
        'has_more': false,
        'latest_seq': 0,
      });
    }
    if (path.endsWith('/canvas/media-slots')) {
      return jsonResponse({'slots': <Object>[]});
    }
    if (path.endsWith('/canvas/object-locks')) {
      return jsonResponse({'object_ids': <Object>[]});
    }
    return jsonResponse(<Object>[]);
  });
}

/// Mirrors the conversation pane's choice: the canvas while open, else the call.
class _Pane extends ConsumerWidget {
  const _Pane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(canvasOpenProvider);
    return id != null
        ? CanvasPane(channelId: id)
        : const VoiceScreen(channelId: 'channel-1');
  }
}

class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  final harness = VoiceHarness();
  final session = FakeSession();

  ProviderContainer get container => harness.container;

  Future<void> start(List<VoiceParticipant> people, {Size? size}) async {
    tester.view.physicalSize = size ?? const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = harness.controllerWith(
      session,
      _api(),
      extraOverrides: [
        syncControllerProvider.overrideWith(NoopSyncController.new),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        voiceRosterProvider.overrideWith(
          (ref, channelId) =>
              const Stream<List<VoiceRosterParticipant>>.empty(),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: _Pane()),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    session.emitParticipants(people);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> openCanvas() async {
    container.read(canvasOpenProvider.notifier).state = 'channel-1';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> closeCanvas() async {
    container.read(canvasOpenProvider.notifier).state = null;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> leave() =>
      container.read(voiceControllerProvider.notifier).leave();
}

void main() {
  final crowd = [for (var i = 0; i < 24; i++) _person(i)];

  testWidgets('the canvas returns to its camera', (tester) async {
    final rig = _Rig(tester);
    addTearDown(rig.harness.dispose);
    await rig.start(crowd);

    await rig.openCanvas();
    await tester.pump(const Duration(milliseconds: 100));
    surfaceDocument(tester).setCamera(
      Camera(
        x: 1500,
        y: 1100,
        zoom: boardFitZoom(canvasBoard, surfaceDocument(tester).viewport) * 3,
      ),
    );
    final panned = surfaceDocument(tester).camera;
    expect(surfaceDocument(tester).isFitted, isFalse);
    await rig.closeCanvas();

    await rig.openCanvas();
    await tester.pump(const Duration(milliseconds: 100));
    expect(surfaceDocument(tester).camera, panned);
    await rig.leave();
  });

  testWidgets('a followed view wins over the kept camera', (tester) async {
    final rig = _Rig(tester);
    addTearDown(rig.harness.dispose);
    await rig.start(crowd);

    await rig.openCanvas();
    await tester.pump(const Duration(milliseconds: 100));
    final first = surfaceDocument(tester).camera;
    expect(surfaceDocument(tester).isFitted, isTrue);
    surfaceDocument(
      tester,
    ).setCamera(Camera(x: 1500, y: 1100, zoom: first.zoom * 3));
    rig.container
            .read(canvasEngineProvider('channel-1').notifier)
            .viewRelay
            .following
            .value =
        'u2';
    await rig.closeCanvas();

    await rig.openCanvas();
    await tester.pump(const Duration(milliseconds: 100));
    expect(surfaceDocument(tester).camera, first);
    await rig.leave();
  });
}
