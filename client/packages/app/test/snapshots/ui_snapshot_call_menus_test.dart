// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's microphone, camera and screen share menus in the real shell
/// on a desktop window and a phone, in both themes, with their device lists
/// open. PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this
/// asserts each menu opens without overflow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/call_dock_hint.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_state.dart';
import 'package:slimm_app/src/features/voice/widgets/share_resolution_support.dart';
import 'package:slimm_app/src/providers/sync_controller.dart'
    show SyncStatus, initialSyncCompleteProvider, syncControllerProvider;
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_call_controls_harness.dart';
import '../support/fake_sync.dart';
import '../support/fake_voice.dart';
import '../ui_snapshot_support.dart';

class _MenuSession extends InertSession {
  _MenuSession()
    : super(
        needsSource: true,
        sources: Future.value(const [
          ScreenShareSource(id: 's1', name: 'Screen 1'),
          ScreenShareSource(id: 's2', name: 'Screen 2'),
          ScreenShareSource(id: 'w1', name: 'Slim-m - Firefox', isWindow: true),
        ]),
        supportsInputGate: true,
        supportsAudioInputSelection: true,
        supportsAudioOutputSelection: true,
        audioInputDeviceList: const [
          AudioDevice(id: 'a', label: 'Arctis Nova Pro Wireless Mono'),
          AudioDevice(id: 'b', label: 'EMEET SmartCam C960 4K Analog Stereo'),
          AudioDevice(id: 'c', label: 'Clean Mic'),
        ],
        audioOutputDeviceList: const [
          AudioDevice(id: 'o', label: 'Arctis Nova Pro Wireless Analog Stereo'),
          AudioDevice(id: 'p', label: 'Main'),
          AudioDevice(id: 'q', label: 'HDMI / DisplayPort 2'),
        ],
      ) {
    cameraNeedsSelection = true;
    cameraDeviceList = const [
      CameraDevice(id: 'a', label: 'EMEET SmartCam C960 4K'),
      CameraDevice(id: 'b', label: 'Integrated Camera'),
      CameraDevice(id: 'c', label: 'OBS Virtual Camera'),
    ];
  }

  @override
  Widget cameraViewFor(String identity) => const ColoredBox(
    color: Color(0xFF2D5F7C),
    child: Center(
      child: Text('camera', style: TextStyle(color: Colors.white)),
    ),
  );
}

const _me = VoiceParticipant(
  identity: 'user-nick',
  name: 'Nick',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

VoiceState _call({bool camera = false, bool sharing = false}) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime.now().subtract(const Duration(minutes: 14)),
  microphoneEnabled: true,
  cameraEnabled: camera,
  screenSharing: sharing,
  shareAudio: sharing ? ShareAudio.on : ShareAudio.none,
  participants: [
    VoiceParticipant(
      identity: _me.identity,
      name: _me.name,
      isLocal: true,
      isSpeaking: false,
      isMuted: false,
      isScreenSharing: sharing,
      isCameraOn: camera,
    ),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _open(
  WidgetTester tester,
  String menu, {
  required bool phone,
}) async {
  if (phone) {
    final pattern = switch (menu) {
      'mic' => '^(Mute|Unmute)',
      'camera' => '^(Turn off camera|Turn on camera)',
      _ => r'^You are sharing your screen\. Stop sharing',
    };
    await tester.longPress(find.bySemanticsLabel(RegExp(pattern)).first);
  } else {
    final label = switch (menu) {
      'mic' => 'Microphone options',
      'camera' => 'Camera options',
      _ => 'Screen share options',
    };
    await tester.tap(find.byTooltip(label));
  }
  await _settle(tester);
}

void main() {
  setUpAll(loadRealFonts);
  setUp(
    () => SharedPreferences.setMockInitialValues({
      shareHintSeenKey: true,
      micCueSeenKey: '',
      'slimm.voice.camera_device_id': 'b',
    }),
  );

  const sizes = {'desktop': Size(1280, 800), 'phone': Size(390, 844)};
  const scenes = {
    'mic': 'Microphone',
    'mic-submenu': 'Microphone',
    'camera': 'Camera',
    'camera-submenu': 'Camera',
    'share': 'Sharing',
    'share-submenu': 'Sharing',
  };
  for (final theme in const ['dark', 'light']) {
    for (final size in sizes.entries) {
      for (final scene in scenes.entries) {
        final phone = size.key == 'phone';
        final menu = scene.key.split('-').first;
        final submenu = scene.key.endsWith('submenu');
        testWidgets('${scene.key} menu at ${size.key} ($theme)', (
          tester,
        ) async {
          await renderSurface(
            tester,
            '/channels/c-main',
            phone ? 'phone-portrait' : 'laptop-1280',
            theme,
            'call-${scene.key}-${size.key}-$theme',
            allowNoText: true,
            overrides: [
              syncControllerProvider.overrideWith(
                (ref) => StubSyncController(ref, SyncStatus.live),
              ),
              initialSyncCompleteProvider.overrideWith((ref) => true),
              screenOverlaySupportedProvider.overrideWithValue(true),
              shareDisplayHeightsProvider.overrideWithValue([1080, 1440]),
              voiceControllerProvider.overrideWith(
                (ref) => FakeVoiceController(
                  ref,
                  initial: _call(
                    camera: menu == 'camera',
                    sharing: menu == 'share',
                  ),
                  session: _MenuSession(),
                ),
              ),
            ],
            afterSettle: (tester) async {
              if (!phone) {
                tester.view.physicalSize = size.value;
                await _settle(tester);
              }
              await _open(tester, menu, phone: phone);
              if (submenu) {
                await tester.tap(find.text(scene.value).last);
                await _settle(tester);
              }
            },
          );
        });
      }
    }
  }
}
