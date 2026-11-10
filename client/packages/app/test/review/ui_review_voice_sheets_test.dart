// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pickers and sheets a call opens over its stage: the camera and screen
/// source choices (an anchored dropdown on a wide window, a sheet on a phone)
/// and a bot's call controls.
///
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each one opens without overflow.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/bot_ui_uses.dart'
    show channelBotUiProvider;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/bot_call_chips.dart';
import 'package:slimm_app/src/features/voice/widgets/camera_source_sheet.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_source_sheet.dart';
import 'package:slimm_rtc/rtc.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_voice_support.dart';

const _route = '/channels/c-main';

VoiceState _call(List<VoiceParticipant> people) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: callStartedAgo(),
  participants: people,
);

final _alone = _call([
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', speaking: true),
]);

final _withBots = _call([
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace'),
  reviewPerson('jelly', 'Jellyfin'),
  reviewPerson('mods', 'Mod helper'),
  reviewPerson('music', 'Jukebox'),
]);

const _cameras = [
  CameraDevice(id: 'c0', label: 'EMEET SmartCam C960 4K'),
  CameraDevice(id: 'c1', label: 'Integrated Webcam'),
  CameraDevice(id: 'c2', label: 'OBS Virtual Camera'),
];

const _screens = [
  ScreenShareSource(id: 's0', name: 'Screen 1'),
  ScreenShareSource(id: 's1', name: 'Screen 2'),
  ScreenShareSource(id: 'w0', name: 'Terminal - slim-m', isWindow: true),
  ScreenShareSource(id: 'w1', name: 'Firefox - Design review', isWindow: true),
];

const _bots = [
  api.ChannelBotUi(
    botUserId: 'jelly',
    botUsername: 'jellyfin',
    botDisplayName: 'Jellyfin',
    messageMenu: [],
    callControls: [
      api.BotUiEntry(id: 'prev', label: 'Previous', icon: 'skip_previous'),
      api.BotUiEntry(id: 'pause', label: 'Pause', icon: 'pause'),
      api.BotUiEntry(id: 'skip', label: 'Skip', icon: 'skip_next'),
      api.BotUiEntry(id: 'stop', label: 'Stop', icon: 'stop'),
      api.BotUiEntry(
        id: 'quality',
        label: 'Quality',
        icon: 'settings',
        options: [
          api.BotUiOption(id: 'low', label: 'Low 480p'),
          api.BotUiOption(id: 'high', label: 'High 1080p'),
        ],
      ),
    ],
  ),
  api.ChannelBotUi(
    botUserId: 'mods',
    botUsername: 'modbot',
    botDisplayName: 'Mod helper',
    messageMenu: [],
    callControls: [
      api.BotUiEntry(id: 'mute', label: 'Mute everyone', icon: 'volume_off'),
      api.BotUiEntry(id: 'list', label: 'Raised hands', icon: 'list'),
    ],
  ),
  api.ChannelBotUi(
    botUserId: 'music',
    botUsername: 'jukebox',
    botDisplayName: 'Jukebox with an unreasonably long display name',
    messageMenu: [],
    callControls: [
      api.BotUiEntry(id: 'prev', label: 'Previous', icon: 'skip_previous'),
      api.BotUiEntry(id: 'play', label: 'Play', icon: 'play'),
      api.BotUiEntry(id: 'skip', label: 'Skip', icon: 'skip_next'),
      api.BotUiEntry(id: 'shuffle', label: 'Shuffle', icon: 'shuffle'),
      api.BotUiEntry(id: 'repeat', label: 'Repeat', icon: 'repeat'),
      api.BotUiEntry(id: 'vol', label: 'Volume', icon: 'volume'),
      api.BotUiEntry(id: 'queue', label: 'Queue', icon: 'list'),
      api.BotUiEntry(id: 'cc', label: 'Captions', icon: 'captions'),
    ],
  ),
];

BuildContext _near(WidgetTester tester, Finder control) =>
    tester.element(control.first);

Future<void> _device(
  WidgetTester tester, {
  required String state,
  required String viewport,
  required RegExp control,
  required Future<Object?> Function(BuildContext context) open,
}) => renderReview(
  tester,
  surface: 'sheet-call-device-choice',
  state: state,
  viewport: viewport,
  route: _route,
  overrides: [reviewVoice(_alone)],
  step: (tester, _) async {
    unawaited(open(_near(tester, find.byTooltip(control))));
    await reviewFrames(tester);
  },
);

Future<void> _botSheet(
  WidgetTester tester, {
  required String state,
  required String viewport,
  required String botUserId,
}) => renderReview(
  tester,
  surface: 'sheet-bot-controls',
  state: state,
  viewport: viewport,
  route: _route,
  overrides: [
    reviewVoice(_withBots),
    channelBotUiProvider.overrideWith((ref, channelId) async => _bots),
  ],
  step: (tester, _) async {
    await reviewFrames(tester);
    unawaited(
      showBotControlsSheet(
        context: _near(tester, find.byTooltip(RegExp('^Turn (on|off) camera'))),
        channelId: 'c-main',
        botUserId: botUserId,
      ),
    );
    await reviewFrames(tester);
  },
);

void main() {
  setUpAll(loadRealFonts);

  final camera = RegExp('^Turn (on|off) camera');
  final share = RegExp('^Share a screen');
  for (final viewport in reviewViewports) {
    testWidgets('device choice, cameras, at $viewport', (tester) async {
      await _device(
        tester,
        state: 'cameras',
        viewport: viewport,
        control: camera,
        open: (context) => showCameraDeviceSheet(context, _cameras),
      );
    });

    testWidgets('device choice, screens, at $viewport', (tester) async {
      await _device(
        tester,
        state: 'screens',
        viewport: viewport,
        control: share,
        open: (context) =>
            showScreenSourceSheet(context, _screens, selectedId: 's1'),
      );
    });

    testWidgets('device choice, empty, at $viewport', (tester) async {
      await _device(
        tester,
        state: 'empty',
        viewport: viewport,
        control: camera,
        open: (context) => showCameraDeviceSheet(context, const []),
      );
    });

    testWidgets('bot controls, rows, at $viewport', (tester) async {
      await _botSheet(
        tester,
        state: 'rows',
        viewport: viewport,
        botUserId: 'jelly',
      );
    });

    testWidgets('bot controls, several bots, at $viewport', (tester) async {
      await _botSheet(
        tester,
        state: 'several-bots',
        viewport: viewport,
        botUserId: 'music',
      );
    });
  }
}
