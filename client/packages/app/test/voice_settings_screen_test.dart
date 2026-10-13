// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the voice settings screen: the microphone meter reflects the
/// only real signal `slimm_rtc` exposes (a live call's local participant
/// speaking or not), and screen share quality and join/leave sounds are
/// preferences that survive a relaunch rather than a session-only echo.
///
/// The camera-on-join preference and the microphone/speaker pickers have
/// their own suites, `voice_settings_camera_test.dart` and
/// `voice_settings_audio_devices_test.dart`, split out once this file
/// pushed past the 500-line hard ceiling; all three share
/// `voice_settings_screen_harness.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_settings_screen_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the accented sensitivity tick is the one the thumb sits on', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const VoiceSettingsBody()));
    await tester.pumpAndSettle();

    final tokens = AppTokens.light;
    final slider = tester.widget<AppSlider>(
      find.byWidgetPredicate(
        (w) =>
            w is AppSlider && w.semanticLabel == 'Voice activity sensitivity',
      ),
    );
    final labels = slider.ticks!;
    final fraction = (slider.value - slider.min) / (slider.max - slider.min);
    final thumbOn = labels[(fraction * (labels.length - 1)).round()];
    final accented = [
      for (final label in labels)
        if (tester.widget<Text>(find.text(label)).style?.color == tokens.accent)
          label,
    ];

    expect(accented, [thumbOn]);
  });

  testWidgets(
    'out of a call, the meter says so instead of showing a live level',
    (tester) async {
      await tester.pumpWidget(wrap(const VoiceSettingsBody()));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Join a voice call to see your live input level'),
        findsOneWidget,
      );
      final tween = tester
          .widget<TweenAnimationBuilder<double>>(
            find.byType(TweenAnimationBuilder<double>),
          )
          .tween;
      expect(tween.end, 6.0);
    },
  );

  testWidgets('speaking in a live call raises the meter target', (
    tester,
  ) async {
    final session = FakeSession();
    await tester.pumpWidget(
      wrap(
        const VoiceSettingsBody(),
        overrides: [
          sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: voiceTokenClient(),
            );
            ref.onDispose(api.close);
            return api;
          }),
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: session),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final controller = ProviderScope.containerOf(
      tester.element(find.byType(VoiceSettingsBody)),
    ).read(voiceControllerProvider.notifier);
    await controller.join('channel-1');
    session.emitParticipants(const [
      VoiceParticipant(
        identity: 'me',
        name: 'me',
        isLocal: true,
        isSpeaking: true,
        isMuted: false,
        isScreenSharing: false,
      ),
    ]);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Join a voice call to see your live input level'),
      findsNothing,
    );
    final tween = tester
        .widget<TweenAnimationBuilder<double>>(
          find.byType(TweenAnimationBuilder<double>),
        )
        .tween;
    expect(tween.end, 82.0);
    // Clears the heartbeat timer a connected call now keeps running.
    await controller.leave();
  });

  testWidgets('changing the sensitivity slider persists it', (tester) async {
    await tester.pumpWidget(wrap(const VoiceSettingsBody()));
    await tester.pumpAndSettle();

    final slider = find.byWidgetPredicate(
      (w) => w is AppSlider && w.semanticLabel == 'Voice activity sensitivity',
    );
    await tester.scrollUntilVisible(
      slider,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    // The widget's own registered callback, rather than a drag gesture: this
    // asserts the real reactive wiring without fighting Slider's own hit
    // geometry for a coordinate that lands on 30.
    tester.widget<AppSlider>(slider).onChanged!(30);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('slimm.voice.activity_sensitivity'), 30.0);
  });

  testWidgets(
    'picking a screen share resolution and frame rate persists them',
    (tester) async {
      await tester.pumpWidget(wrap(const VoiceSettingsBody()));
      await tester.pumpAndSettle();

      // The capability check section pushes this below the initial viewport.
      await tester.scrollUntilVisible(
        find.text('1440p'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('1440p'));
      await tester.tap(find.text('60 fps'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('slimm.voice.screen_share_quality'), '1440p60');
    },
  );

  testWidgets('picking watching and camera quality persists both', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const VoiceSettingsBody()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('1440p'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // Data saver is the last segment of watching quality, 1080p the last of camera.
    await tester.tap(find.text('Data saver').first);
    await tester.tap(find.text('1080p').first);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('slimm.voice.receive_video_quality'), 'dataSaver');
    expect(prefs.getString('slimm.voice.camera_quality'), 'high');
  });

  testWidgets(
    'screen share audio is offered only where the platform can publish it',
    (tester) async {
      final unsupported = FakeSession(supportsScreenShareAudio: false);
      await tester.pumpWidget(
        wrap(
          const VoiceSettingsBody(),
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: unsupported),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byWidgetPredicate(
        (w) =>
            w is AppToggle &&
            w.semanticLabel == 'Share audio with a screen share',
      );
      expect(
        toggle,
        findsNothing,
        reason: 'absent, never disabled, where nothing would happen',
      );

      final supported = FakeSession(supportsScreenShareAudio: true);
      await tester.pumpWidget(
        wrap(
          const VoiceSettingsBody(),
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: supported),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
    },
  );

  testWidgets('turning on screen share audio persists it', (tester) async {
    final session = FakeSession(supportsScreenShareAudio: true);
    await tester.pumpWidget(
      wrap(
        const VoiceSettingsBody(),
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: session),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle &&
          w.semanticLabel == 'Share audio with a screen share',
    );
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.screen_share_include_audio'), isTrue);
  });

  testWidgets('turning off join and leave sounds persists it', (tester) async {
    await tester.pumpWidget(wrap(const VoiceSettingsBody()));
    await tester.pumpAndSettle();

    final soundsToggle = find.byWidgetPredicate(
      (w) => w is AppToggle && w.semanticLabel == 'Play join and leave sounds',
    );
    // The capability check section pushes this below the initial viewport.
    await tester.scrollUntilVisible(
      soundsToggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(soundsToggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.join_leave_sounds_enabled'), isFalse);
  });

  testWidgets('turning off the incoming-call sound persists it', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const VoiceSettingsBody()));
    await tester.pumpAndSettle();

    final ringToggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle &&
          w.semanticLabel == 'Play a sound for an incoming call',
    );
    // The capability check section pushes this below the initial viewport.
    await tester.scrollUntilVisible(
      ringToggle,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(ringToggle);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('slimm.voice.call_ring_sound_enabled'), isFalse);
  });

  testWidgets('the Calls pane holds voice settings, with no second route', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
    );
    addTearDown(container.dispose);
    container.read(preferencesProvider);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(1200, 900)),
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const PersonalSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Voice & screen share'));
    await tester.pumpAndSettle();

    expect(find.byType(VoiceSettingsBody), findsOneWidget);
    // The link row that used to push a second screen is gone with it.
    expect(find.text('Microphone, screen share, sounds'), findsNothing);
  });
}
