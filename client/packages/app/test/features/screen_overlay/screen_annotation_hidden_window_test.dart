// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mark held for someone the roster has not caught up with shows once they
/// join, also while the window is in the tray and draws no frames.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/window_lifecycle.dart';
import 'overlay_rig.dart';

const _carol = VoiceParticipant(
  identity: 'carol',
  name: 'carol',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _sharer = VoiceParticipant(
  identity: 'sharer',
  name: 'sharer',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _consent = api.CanvasScreenAnnotation(
  channelId: 'call',
  userId: 'sharer',
  targetUserId: 'sharer',
  kind: 'consent',
  points: [],
  ended: false,
  allowed: true,
);

void main() {
  testWidgets('a held mark shows when its sender joins with no frame drawn', (
    tester,
  ) async {
    final rig = OverlayRig(
      initial: VoiceState(
        channelId: 'call',
        state: VoiceSessionState.connected,
        participants: [rigMe(), _sharer],
      ),
    );
    addTearDown(rig.container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: const SizedBox(),
      ),
    );
    final feed = rig.container.read(screenAnnotationFeedProvider);
    await tester.pump();
    await hideTestWindow(tester);

    rig.sync.events.add(_consent);
    rig.annotate(target: 'sharer', from: 'carol');
    await tester.idle();
    expect(feed.marksFor('sharer'), isEmpty);

    rig.voice.update(
      (s) => s.copyWith(participants: [...s.participants, _carol]),
    );
    await tester.idle();

    expect(feed.marksFor('sharer'), hasLength(1));
  });
}
