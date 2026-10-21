// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock's split buttons: the mic gets an options menu backed by the
/// Voice settings providers, every caret toggles its menu, a menu clears the
/// dock, the speaker button is gone and a camera that is on is lit.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/noise_suppression.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _usb = AudioDevice(id: 'usb-1', label: 'USB headset');
const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);
const _connected = VoiceFlags(state: VoiceSessionState.connected);

InertSession _session() => InertSession(
  supportsInputGate: true,
  supportsAudioInputSelection: true,
  audioInputDeviceList: const [_usb],
  supportsAudioOutputSelection: true,
);

Future<_Dock> _pumpDock(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = _session();
  final container = await pumpVoiceCallDock(
    tester,
    _connected,
    width: 900,
    session: session,
  );
  container.read(voiceSettingsControllerProvider);
  await tester.pump();
  await tester.pump();
  return (container: container, session: session);
}

typedef _Dock = ({ProviderContainer container, InertSession session});

Rect _dockRect(WidgetTester tester) =>
    tester.getRect(find.byType(FloatingDockCard));

void main() {
  testWidgets('the speaker button is a one-click deafen with no output menu', (
    tester,
  ) async {
    final dock = await _pumpDock(tester);
    expect(find.byTooltip('Switch speaker'), findsNothing);
    expect(find.byTooltip(RegExp('^Deafen')), findsOneWidget);
    expect(find.byIcon(AppIcons.speaker), findsOneWidget);

    await tester.tap(find.byTooltip(RegExp('^Deafen')));
    await tester.pump();
    expect(dock.session.deafenCalls, [true]);
    expect(find.byType(AppMenu), findsNothing);
  });

  testWidgets(
    'the mic menu lists devices and noise suppression, and applies them',
    (tester) async {
      final dock = await _pumpDock(tester);
      await tester.tap(find.byTooltip('Microphone options'));
      await tester.pumpAndSettle();

      expect(find.text('USB headset'), findsOneWidget);
      expect(find.text('Standard'), findsOneWidget);
      expect(find.text('Strong'), findsOneWidget);
      expect(find.text('Voice settings'), findsOneWidget);

      await tester.tap(find.text('Strong'));
      await tester.pumpAndSettle();
      expect(
        dock.container.read(noiseSuppressionProvider),
        NoiseSuppressionChoice.strong,
      );

      await tester.tap(find.byTooltip('Microphone options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USB headset'));
      await tester.pumpAndSettle();
      expect(dock.session.lastSelectedAudioInput?.id, 'usb-1');
      expect(
        dock.container.read(voiceSettingsControllerProvider).audioInputDeviceId,
        'usb-1',
      );
    },
  );

  testWidgets('a second press on any caret closes its menu', (tester) async {
    await _pumpDock(tester);
    for (final label in ['Microphone options', 'Screen share options']) {
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      expect(find.byType(AppMenu), findsOneWidget, reason: '$label opens');

      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      expect(find.byType(AppMenu), findsNothing, reason: '$label closes');
    }
  });

  testWidgets('a menu opens above the dock without covering it', (
    tester,
  ) async {
    await _pumpDock(tester);
    await tester.tap(find.byTooltip('Screen share options'));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.byType(AppMenu));
    expect(menu.bottom, lessThanOrEqualTo(_dockRect(tester).top));
    expect(menu.top, greaterThanOrEqualTo(0));
  });

  testWidgets('a menu taller than the room above the dock is cut to fit', (
    tester,
  ) async {
    await _pumpDock(tester);
    tester.view.physicalSize = const Size(900, 260);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Microphone options'));
    await tester.pumpAndSettle();

    final menu = tester.getRect(
      find.ancestor(
        of: find.byType(AppMenu),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(menu.bottom, lessThanOrEqualTo(_dockRect(tester).top));
    expect(menu.top, greaterThanOrEqualTo(0));
  });

  testWidgets('a camera that is on is lit like a live share', (tester) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, cameraEnabled: true),
    );
    final chip =
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.byIcon(AppIcons.camera),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    expect(chip.color, AppTokens.light.accentSoft);
  });

  testWidgets('alone on a narrow dock the music rides in the mic menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(340, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpVoiceCallDock(
      tester,
      _connected,
      width: 340,
      session: _session(),
      extraOverrides: [
        voiceParticipantsProvider.overrideWithValue(const [_me]),
      ],
    );
    await tester.pump();

    expect(find.byTooltip(RegExp('music')), findsNothing);
    final rows = find.byType(FloatingDockCard);
    expect(tester.getSize(rows).height, lessThan(80), reason: 'one call row');

    await tester.tap(find.byTooltip('Microphone options'));
    await tester.pumpAndSettle();
    expect(find.text('MUSIC WHILE ALONE'), findsOneWidget);
    expect(find.text('Play music'), findsOneWidget);
  });
}
