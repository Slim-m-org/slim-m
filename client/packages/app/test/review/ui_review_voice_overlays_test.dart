// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call puts over the whole app: full screen video, the incoming call
/// prompt, and the toast a hang-up leaves behind.
///
/// Full screen video forces its own dark theme, so it writes -dark only.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each one lays out without overflow.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/messages/widgets/pinned_messages_sheet.dart';
import 'package:slimm_app/src/features/voice/providers/call_recap.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_rtc/rtc.dart';

import '../support/fake_voice.dart';
import '../ui_snapshot_support.dart';
import 'ui_review_voice_support.dart';

VoiceState _call(List<VoiceParticipant> people) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: callStartedAgo(),
  participants: people,
);

final _sharing = _call([
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', sharing: true, camera: true),
  reviewPerson('user-grace', 'Grace Hopper'),
]);

BuildContext _anyContext(WidgetTester tester) =>
    tester.element(find.byTooltip(RegExp('^Turn (on|off) camera')).first);

Future<void> _fullscreen(
  WidgetTester tester, {
  required String state,
  required String viewport,
  required FullscreenVideoKind kind,
  bool revealDock = false,
}) => renderReview(
  tester,
  surface: 'overlay-fullscreen-video',
  state: state,
  viewport: viewport,
  route: '/channels/c-main',
  themes: const ['dark'],
  overrides: [reviewVoice(_sharing)],
  step: (tester, _) async {
    unawaited(
      showFullscreenVideo(
        _anyContext(tester),
        identity: 'user-ada',
        label: kind == FullscreenVideoKind.camera
            ? 'Ada Lovelace'
            : "Ada Lovelace's screen",
        kind: kind,
      ),
    );
    await reviewFrames(tester);
    if (!revealDock) return;
    await tester.tap(find.byTooltip('Show controls'));
    await reviewFrames(tester);
  },
);

const _ring = IncomingDmCallRing(
  channelId: 'c-dm-ada',
  ringId: 'ring-1',
  callerId: 'user-ada',
);

const _adaProfile = api.UserProfile(
  id: 'user-ada',
  username: 'ada',
  displayName: 'Ada Lovelace',
  createdAt: 0,
);

const _longProfile = api.UserProfile(
  id: 'user-long-name',
  username: 'christoph',
  displayName: 'Christoph Bartholomew Fitzgerald-Huang III',
  createdAt: 0,
);

Future<void> _incoming(
  WidgetTester tester, {
  required String state,
  required String viewport,
  required IncomingDmCallRing ring,
  api.UserProfile? caller,
  CallKitPhase callKit = CallKitPhase.none,
  ReviewStep? step,
}) => renderReview(
  tester,
  surface: 'overlay-incoming-call',
  state: state,
  viewport: viewport,
  route: '/channels/c-general',
  overrides: [
    dmCallRingControllerProvider.overrideWith(
      (ref) =>
          PinnedRing(ref, DmCallRingState(incoming: ring, callKit: callKit)),
    ),
    userProfileProvider(ring.callerId).overrideWith((ref) async => caller),
  ],
  step: step,
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports) {
    testWidgets('fullscreen video, share, at $viewport', (tester) async {
      await _fullscreen(
        tester,
        state: 'share',
        viewport: viewport,
        kind: FullscreenVideoKind.screenShare,
      );
    });

    testWidgets('fullscreen video, camera, at $viewport', (tester) async {
      await _fullscreen(
        tester,
        state: 'camera',
        viewport: viewport,
        kind: FullscreenVideoKind.camera,
      );
    });

    testWidgets('fullscreen video, dock revealed, at $viewport', (
      tester,
    ) async {
      await _fullscreen(
        tester,
        state: 'dock-revealed',
        viewport: viewport,
        kind: FullscreenVideoKind.screenShare,
        revealDock: true,
      );
    });

    testWidgets('incoming call, ringing, at $viewport', (tester) async {
      await _incoming(
        tester,
        state: 'ringing',
        viewport: viewport,
        ring: _ring,
        caller: _adaProfile,
      );
    });

    testWidgets('incoming call, unknown caller, at $viewport', (tester) async {
      await _incoming(
        tester,
        state: 'unknown-caller',
        viewport: viewport,
        ring: const IncomingDmCallRing(
          channelId: 'c-dm-ghost',
          ringId: 'ring-2',
          callerId: 'user-ghost',
        ),
      );
    });

    testWidgets('incoming call, group, at $viewport', (tester) async {
      await _incoming(
        tester,
        state: 'group',
        viewport: viewport,
        ring: const IncomingDmCallRing(
          channelId: 'c-group-dm',
          ringId: 'ring-3',
          callerId: 'user-long-name',
        ),
        caller: _longProfile,
      );
    });

    testWidgets('incoming call, over a sheet, at $viewport', (tester) async {
      await _incoming(
        tester,
        state: 'over-sheet',
        viewport: viewport,
        ring: _ring,
        caller: _adaProfile,
        step: (tester, _) async {
          unawaited(
            showPinnedMessagesSheet(
              tester.element(find.text('general').first),
              'c-general',
            ),
          );
          await reviewFrames(tester);
        },
      );
    });

    testWidgets('incoming call, quieted by the system call screen, at '
        '$viewport', (tester) async {
      await _incoming(
        tester,
        state: 'quieted',
        viewport: viewport,
        ring: _ring,
        caller: _adaProfile,
        callKit: CallKitPhase.ringing,
      );
    });

    testWidgets('hang-up recap toast at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'toast-hang-up-recap',
        viewport: viewport,
        route: '/channels/c-general',
        overrides: [reviewVoice(_sharing)],
        step: (tester, container) async {
          final now = DateTime.now();
          (container.read(voiceControllerProvider.notifier)
                  as FakeVoiceController)
              .set(
                VoiceState(
                  recap: CallRecap(
                    channelId: 'c-main',
                    startedAt: now.subtract(const Duration(minutes: 18)),
                    endedAt: now,
                    others: [
                      CallParticipantActivity(
                        identity: 'user-ada',
                        name: 'Ada Lovelace',
                        joinedAt: now.subtract(const Duration(minutes: 17)),
                      ),
                    ],
                    sharedScreen: false,
                    usedCamera: false,
                  ),
                  justLeftChannelId: 'c-main',
                  justLeftAt: now,
                ),
              );
          await reviewFrames(tester);
        },
      );
    });
  }
}
