// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The menus a call opens, over the real call stage: the camera caret, the
/// right-click or long-press menu on a participant tile and on a share tile,
/// and the quality pick on a share's control strip.
///
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each menu opens without overflow.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart'
    show myVisibleChannelsProvider;
import 'package:slimm_app/src/features/voice/providers/popout_window.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart'
    show voiceRosterProvider;
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
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

final _quiet = _call([
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', speaking: true),
  reviewPerson('user-grace', 'Grace Hopper', muted: true),
]);

final _sharing = _call([
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', sharing: true, camera: true),
  reviewPerson('user-bo', 'Bo', sharing: true),
  reviewPerson('user-grace', 'Grace Hopper'),
]);

final _ownShare = _call([
  reviewPerson('user-nick', 'Nick', local: true, sharing: true, camera: true),
  reviewPerson('user-ada', 'Ada Lovelace'),
], camera: true);

Finder _tile(String identity) => find.byWidgetPredicate(
  (w) => w is CallParticipantTile && w.participant.identity == identity,
);

final _stage = find.byWidgetPredicate((w) => w is ScreenShareStage);

const _rooms = [
  api.Channel(
    id: 'c-lounge',
    name: 'lounge',
    kind: 'voice',
    createdAt: 0,
    categoryId: 'cat-voice',
    userLimit: 6,
    permissions: -1,
  ),
  api.Channel(
    id: 'c-pairing',
    name: 'pairing',
    kind: 'voice',
    createdAt: 0,
    categoryId: 'cat-voice',
    userLimit: 2,
    permissions: -1,
  ),
];

const _pairing = [
  api.VoiceRosterParticipant(userId: 'user-priya', displayName: 'Priya'),
  api.VoiceRosterParticipant(userId: 'user-tomas', displayName: 'Tomas'),
];

Future<void> _seedRooms(ProviderContainer container) async {
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(_rooms);
}

Future<void> _participantMenu(
  WidgetTester tester, {
  required String surfaceState,
  required String viewport,
  required VoiceState call,
  required String target,
  int? permissions,
  Future<void> Function(WidgetTester tester)? then,
}) => renderReview(
  tester,
  surface: 'menu-call-participant',
  state: surfaceState,
  viewport: viewport,
  route: _route,
  overrides: [
    reviewVoice(call),
    if (permissions != null)
      myPermissionsProvider.overrideWithValue(permissions),
    popOutSupportedProvider.overrideWithValue(viewport == 'desktop'),
    myVisibleChannelsProvider.overrideWith((ref) async => _rooms),
    voiceRosterProvider.overrideWith(
      (ref, id) => Stream.value(id == 'c-pairing' ? _pairing : const []),
    ),
  ],
  seed: _seedRooms,
  step: (tester, _) async {
    await reviewOpenMenu(tester, viewport, _tile(target));
    if (then != null) await then(tester);
  },
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports) {
    testWidgets('camera options menu at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-menu-camera-options',
        state: 'open',
        viewport: viewport,
        route: _route,
        overrides: [
          reviewVoice(
            _ownShare,
            session: ReviewVoiceSession(
              cameraNeedsSelection: true,
              cameraDeviceList: const [
                CameraDevice(id: 'c0', label: 'EMEET SmartCam C960 4K'),
                CameraDevice(id: 'c1', label: 'Integrated Webcam'),
                CameraDevice(id: 'c2', label: 'OBS Virtual Camera'),
              ],
            ),
          ),
        ],
        step: (tester, _) async {
          final control = viewport == 'phone'
              ? find.byTooltip(RegExp('^Turn off camera'))
              : find.byTooltip('Camera options');
          if (viewport == 'phone') {
            await reviewLongPress(tester, control);
          } else {
            await tester.tap(control);
            await reviewFrames(tester);
          }
        },
      );
    });

    testWidgets('participant menu, someone else, at $viewport', (tester) async {
      await _participantMenu(
        tester,
        surfaceState: 'other',
        viewport: viewport,
        call: _quiet,
        target: 'user-ada',
        permissions: 0,
      );
    });

    testWidgets('participant menu, moderator, at $viewport', (tester) async {
      await _participantMenu(
        tester,
        surfaceState: 'moderator',
        viewport: viewport,
        call: _quiet,
        target: 'user-ada',
      );
    });

    testWidgets('participant menu, stream rows, at $viewport', (tester) async {
      await _participantMenu(
        tester,
        surfaceState: 'stream-rows',
        viewport: viewport,
        call: _sharing,
        target: 'user-ada',
      );
    });

    testWidgets('participant menu, move submenu, at $viewport', (tester) async {
      await _participantMenu(
        tester,
        surfaceState: 'move-submenu',
        viewport: viewport,
        call: _quiet,
        target: 'user-ada',
        then: (tester) async {
          await tester.tap(find.text('Move to...'));
          await reviewFrames(tester);
        },
      );
    });

    testWidgets('participant menu, own tile, at $viewport', (tester) async {
      await _participantMenu(
        tester,
        surfaceState: 'own',
        viewport: viewport,
        call: _ownShare,
        target: 'user-nick',
      );
    });

    testWidgets('share tile menu at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-menu-share-tile',
        state: 'open',
        viewport: viewport,
        route: _route,
        overrides: [
          reviewVoice(_sharing),
          popOutSupportedProvider.overrideWithValue(viewport == 'desktop'),
        ],
        step: (tester, _) => reviewOpenMenu(tester, viewport, _stage.first),
      );
    });

    testWidgets('stream quality menu at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'voice-menu-stream-quality',
        state: 'open',
        viewport: viewport,
        route: _route,
        overrides: [reviewVoice(_sharing)],
        step: (tester, _) async {
          if (viewport == 'phone') {
            await tester.tap(_stage.first);
          } else {
            await reviewHover(tester, _stage.first);
          }
          await reviewFrames(tester);
          await tester.tap(find.byIcon(AppIcons.requestLatency).first);
          await reviewFrames(tester);
        },
      );
    });
  }
}
