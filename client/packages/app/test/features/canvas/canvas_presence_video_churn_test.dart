// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dragging a tile must never remount its video: each remount tears down and rebuilds a native renderer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/voice/widgets/video_health_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';
import 'presence_stack.dart';

const _noor = VoiceParticipant(
  identity: 'user-noor',
  name: 'Noor',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _avery = VoiceParticipant(
  identity: 'user-avery',
  name: 'Avery',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
  isCameraOn: true,
);

class _Counts {
  int created = 0;
  int disposed = 0;
}

class _Probe extends StatefulWidget {
  const _Probe(this.counts);
  final _Counts counts;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.counts.created++;
  }

  @override
  void dispose() {
    widget.counts.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: SizedBox(width: 1000, height: 800, child: child)),
  ),
);

void main() {
  testWidgets('dragging camera and share tiles never remounts their video', (
    tester,
  ) async {
    final cameras = _Counts();
    final shares = _Counts();
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();
    final health = ValueNotifier<Map<String, VideoTileHealth>>({});
    await tester.pumpWidget(
      _wrap(
        PresenceStack(
          document: document,
          participants: const [_noor, _avery],
          cameraViewFor: (id) => voiceVideoView(
            participants: const [_noor, _avery],
            health: health,
            identity: id,
            view: _Probe(cameras),
            screenShare: false,
            declaresInterest: false,
          ),
          screenShareViewFor: (id) => voiceVideoView(
            participants: const [_noor, _avery],
            health: health,
            identity: id,
            view: _Probe(shares),
            screenShare: true,
            declaresInterest: false,
          ),
          overrides: overrides,
          onCommit: (_, __) {},
        ),
      ),
    );
    await tester.pump();
    final created = (cameras.created, shares.created);
    expect(created.$1, greaterThan(0));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CanvasPresenceBubble).first),
    );
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(25, 15));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(overrides.stateFor('camera:user-avery').rect, isNotNull);
    expect((cameras.created, shares.created), created);
    expect(cameras.disposed, 0);
    expect(shares.disposed, 0);
  });

  testWidgets('a remote member dragging a tile never remounts its video', (
    tester,
  ) async {
    final cameras = _Counts();
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();
    final sync = CanvasMediaSlotSync(
      channelId: 'c1',
      client: testApi((_) async => throw StateError('no http expected')),
      overrides: overrides,
      selfId: () => 'me',
    );
    addTearDown(sync.dispose);
    await tester.pumpWidget(
      _wrap(
        PresenceStack(
          document: document,
          participants: const [_noor],
          cameraViewFor: (_) => _Probe(cameras),
          screenShareViewFor: (_) => const SizedBox(),
          overrides: overrides,
          onCommit: (_, __) {},
        ),
      ),
    );
    await tester.pump();
    final created = cameras.created;

    for (var i = 0; i < 12; i++) {
      sync.applyRemotePreview(
        api.CanvasMediaSlotPreview(
          channelId: 'c1',
          userId: 'bob',
          kind: 'camera',
          slotUserId: 'user-noor',
          x: 100.0 + i * 20,
          y: 80,
          w: 220,
          h: 160,
          ended: i == 11,
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(cameras.created, created);
    expect(cameras.disposed, 0);
  });
}
