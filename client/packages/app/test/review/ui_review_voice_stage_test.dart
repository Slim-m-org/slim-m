// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stage in the states a review wants to judge: a crowded call with a
/// share and a filmstrip, a remote camera that is paused, stalled or stopped,
/// our own bad connection, and our own preview paused in the background.
///
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each state lays out without overflow.
library;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_health.dart';
import 'package:slimm_rtc/rtc.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_voice_support.dart';

const _route = '/channels/c-main';

VoiceState _call(List<VoiceParticipant> people, {bool camera = false}) =>
    VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
      connectedAt: callStartedAgo(),
      cameraEnabled: camera,
      participants: people,
    );

final _eight = [
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', sharing: true, camera: true),
  reviewPerson('user-grace', 'Grace Hopper', muted: true),
  reviewPerson('user-linus', 'Linus', camera: true),
  reviewPerson('user-margaret', 'Margaret Hamilton'),
  reviewPerson(
    'user-long-name',
    'Christoph Bartholomew Fitzgerald-Huang III',
    muted: true,
  ),
  reviewPerson('user-priya', 'Priya', camera: true),
  reviewPerson('user-tomas', 'Tomas', speaking: true),
];

final _cameraCall = _call([
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', camera: true, speaking: true),
  reviewPerson('user-grace', 'Grace Hopper', muted: true),
]);

ReviewVoiceSession _withHealth(VideoTileHealth health) => ReviewVoiceSession()
  ..videoHealth.value = {
    videoSubscriptionKey(identity: 'user-ada', screenShare: false): health,
  };

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports) {
    testWidgets('voice call stage, many people, at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-call-stage',
        state: 'many',
        viewport: viewport,
        route: _route,
        overrides: [reviewVoice(_call(_eight))],
      );
    });

    for (final health in const {
      'camera-paused': VideoTileHealth.paused,
      'camera-stalled': VideoTileHealth.stalled,
      'camera-stopped': VideoTileHealth.stopped,
    }.entries) {
      testWidgets('voice call stage, ${health.key}, at $viewport', (
        tester,
      ) async {
        await renderReview(
          tester,
          surface: 'voice-call-stage',
          state: health.key,
          viewport: viewport,
          route: _route,
          overrides: [
            reviewVoice(_cameraCall, session: _withHealth(health.value)),
          ],
        );
      });
    }

    testWidgets('voice call stage, poor connection, at $viewport', (
      tester,
    ) async {
      await renderReview(
        tester,
        surface: 'voice-call-stage',
        state: 'poor-connection',
        viewport: viewport,
        route: _route,
        overrides: [
          reviewVoice(_cameraCall),
          poorConnectionsProvider.overrideWith(
            (ref) => ListenableState(ValueNotifier({'user-nick'})),
          ),
        ],
      );
    });

    testWidgets('voice call stage, preview paused, at $viewport', (
      tester,
    ) async {
      await renderReview(
        tester,
        surface: 'voice-call-stage',
        state: 'preview-paused',
        viewport: viewport,
        route: _route,
        overrides: [
          reviewVoice(
            _call([
              reviewPerson('user-nick', 'Nick', local: true, camera: true),
              reviewPerson('user-ada', 'Ada Lovelace', speaking: true),
            ], camera: true),
          ),
          localPreviewPausedProvider.overrideWithValue(true),
        ],
      );
    });
  }
}
