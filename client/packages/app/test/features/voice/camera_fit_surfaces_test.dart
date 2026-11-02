// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each surface tells the camera view how to fit: a grid tile letterboxes only
/// a portrait feed, full screen and the pop-out always show the whole picture.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

/// A camera view that records the fit its surface gave it.
class _FitProbe extends StatelessWidget {
  const _FitProbe(this.seen);

  final List<CameraFit> seen;

  @override
  Widget build(BuildContext context) {
    seen.add(CameraFitScope.of(context));
    return const ColoredBox(color: Color(0xFF336699));
  }
}

class _ProbeVoice extends FakeVoiceController {
  _ProbeVoice(super.ref, this.seen)
    : super(
        session: FakeSession(),
        initial: const VoiceState(
          channelId: 'c-main',
          state: VoiceSessionState.connected,
          participants: [_ada],
        ),
      );

  final List<CameraFit> seen;

  @override
  Widget cameraViewFor(String identity, {bool declaresInterest = true}) =>
      _FitProbe(seen);
}

Widget _app(List<CameraFit> seen, Widget Function(BuildContext) home) =>
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith((ref) => _ProbeVoice(ref, seen)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(builder: home),
      ),
    );

void main() {
  testWidgets('a grid tile letterboxes a portrait feed and covers otherwise', (
    tester,
  ) async {
    final seen = <CameraFit>[];
    await tester.pumpWidget(
      _app(
        seen,
        (_) => Scaffold(
          body: CallParticipantTile(
            participant: _ada,
            cameraView: _FitProbe(seen),
          ),
        ),
      ),
    );
    expect(seen, [CameraFit.coverUnlessPortrait]);
  });

  testWidgets('full screen shows the whole camera picture', (tester) async {
    final seen = <CameraFit>[];
    await tester.pumpWidget(
      _app(
        seen,
        (context) => TextButton(
          onPressed: () => showFullscreenVideo(
            context,
            identity: 'u-ada',
            label: 'Ada',
            kind: FullscreenVideoKind.camera,
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(seen, isNotEmpty);
    expect(seen.toSet(), {CameraFit.contain});
  });

  testWidgets('the pop-out shows the whole camera picture', (tester) async {
    final seen = <CameraFit>[];
    await tester.pumpWidget(
      _app(
        seen,
        (_) => const PopOutWindowView(
          feed: (identity: 'u-ada', name: 'Ada', kind: FeedKind.camera),
        ),
      ),
    );
    await tester.pump();
    expect(seen, isNotEmpty);
    expect(seen.toSet(), {CameraFit.contain});
  });
}
