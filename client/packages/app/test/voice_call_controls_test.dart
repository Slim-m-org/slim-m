// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that the share control never claims a share that is not happening,
/// applies the quality already chosen in Voice settings without asking
/// again, and cannot be re-entered by a fast double-tap while it is still
/// enumerating sources.
///
/// On iOS, asking to share only asks the system to offer a broadcast picker.
/// Capture runs in a separate ReplayKit extension process, and nothing is
/// published until the user starts the broadcast there. A control that lights
/// up on the request is describing something nobody can see, which is what the
/// owner reported as screen share doing nothing.
///
/// `voice_call_controls_focus_test.dart` covers keyboard-focus reachability,
/// split out to keep this file under the review budget.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

/// The shortcut hint every tooltip now carries, exactly as the control row
/// builds it, so a key rebind here cannot silently desync from the widget.
String _hint(AppAction action) => ' (${describeAppAction(action).join('+')})';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a share awaiting a broadcast reads as waiting, not as on', (
    tester,
  ) async {
    await pumpControls(
      tester,
      const VoiceFlags(
        state: VoiceSessionState.connected,
        awaitingBroadcast: true,
      ),
    );

    expect(find.byIcon(AppIcons.screenShare), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Waiting for you to start the broadcast. Tap to cancel.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a live share reads as sharing', (tester) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, screenSharing: true),
    );

    expect(find.byIcon(AppIcons.screenShare), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.bySemanticsLabel('Stop sharing${_hint(AppAction.toggleShareCall)}'),
      findsOneWidget,
    );
  });

  testWidgets(
    'sharing applies the quality already saved in Voice settings, asking nothing',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        qualityKey: ScreenShareQuality.crisp.name,
      });
      final session = InertSession();
      final container = await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        session: session,
      );

      // Warms the async load, or the tap would only see the default state.
      container.read(voiceSettingsControllerProvider);
      await container.read(preferencesProvider.future);
      await tester.pump();
      expect(
        container.read(voiceSettingsControllerProvider).screenShareQuality,
        ScreenShareQuality.crisp,
      );

      await tester.tap(
        find.byTooltip('Share a screen${_hint(AppAction.toggleShareCall)}'),
      );
      await tester.pumpAndSettle();

      // The setting is authoritative, not a pre-fill for one more question.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(session.screenShareCalls, hasLength(1));
      expect(session.screenShareCalls.single.quality, ScreenShareQuality.crisp);
    },
  );

  testWidgets(
    'sharing applies the saved audio choice already in Voice settings, asking nothing',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'slimm.voice.screen_share_include_audio': true,
      });
      final session = InertSession();
      final container = await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        session: session,
      );

      container.read(voiceSettingsControllerProvider);
      await container.read(preferencesProvider.future);
      await tester.pump();
      expect(
        container.read(voiceSettingsControllerProvider).screenShareIncludeAudio,
        isTrue,
      );

      await tester.tap(
        find.byTooltip('Share a screen${_hint(AppAction.toggleShareCall)}'),
      );
      await tester.pumpAndSettle();

      expect(session.screenShareCalls, hasLength(1));
      expect(session.screenShareCalls.single.includeAudio, isTrue);
    },
  );

  testWidgets(
    "sharing reads the space's screen-share ceiling and passes it on",
    (tester) async {
      final session = InertSession();
      await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        session: session,
        screenShareMaxHeight: 720,
      );

      await tester.tap(
        find.byTooltip('Share a screen${_hint(AppAction.toggleShareCall)}'),
      );
      await tester.pumpAndSettle();

      expect(session.screenShareCalls.single.maxHeight, 720);
    },
  );

  testWidgets(
    'a server too old to report a ceiling shares with no cap rather than '
    'refusing',
    (tester) async {
      final session = InertSession();
      await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        session: session,
        screenShareMaxHeight: null,
      );

      await tester.tap(
        find.byTooltip('Share a screen${_hint(AppAction.toggleShareCall)}'),
      );
      await tester.pumpAndSettle();

      expect(session.screenShareCalls.single.maxHeight, isNull);
    },
  );

  testWidgets("sharing defaults to not sharing this device's audio", (
    tester,
  ) async {
    final session = InertSession();
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      session: session,
    );

    await tester.tap(
      find.byTooltip('Share a screen${_hint(AppAction.toggleShareCall)}'),
    );
    await tester.pumpAndSettle();

    expect(session.screenShareCalls.single.includeAudio, isFalse);
  });

  testWidgets('a fast double-tap on share enumerates sources only once', (
    tester,
  ) async {
    final sourcesCompleter = Completer<List<ScreenShareSource>>();
    final session = InertSession(
      needsSource: true,
      sources: sourcesCompleter.future,
    );
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      session: session,
    );

    final shareButton = find.byTooltip(
      'Share a screen${_hint(AppAction.toggleShareCall)}',
    );
    // Both taps land before the source lookup they raced to start answers.
    await tester.tap(shareButton);
    await tester.pump();
    await tester.tap(shareButton);
    await tester.pump();

    sourcesCompleter.complete(const [
      ScreenShareSource(id: '1', name: 'Screen 1'),
      ScreenShareSource(id: '2', name: 'Screen 2'),
    ]);
    await tester.pumpAndSettle();

    expect(session.sourceFetchCount, 1);
    // The sheet's own body copy: its tooltip is also "Share a screen".
    expect(
      find.text('Everyone in the call will see it until you stop sharing.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'on Linux the portal picks, so this app never opens a second picker',
    (tester) async {
      final session = InertSession(
        needsSource: true,
        sources: Future.value(const [
          ScreenShareSource(id: '1', name: 'Screen 1'),
          ScreenShareSource(id: '2', name: 'Screen 2'),
        ]),
        sourcePickerUseful: false,
      );
      await pumpControls(
        tester,
        const VoiceFlags(state: VoiceSessionState.connected),
        session: session,
      );

      await tester.tap(
        find.byTooltip('Share a screen${_hint(AppAction.toggleShareCall)}'),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Everyone in the call will see it until you stop sharing.'),
        findsNothing,
        reason:
            'xdg-desktop-portal already asks; this sheet would be a second '
            'dialog for the same choice',
      );
      expect(session.screenShareCalls, hasLength(1));
      expect(session.screenShareCalls.single.sourceId, '1');
    },
  );

  testWidgets('the camera button turns the camera on', (tester) async {
    final session = InertSession();
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      session: session,
    );

    expect(
      find.byTooltip('Turn on camera${_hint(AppAction.toggleCameraCall)}'),
      findsOneWidget,
    );

    await tester.tap(
      find.byTooltip('Turn on camera${_hint(AppAction.toggleCameraCall)}'),
    );
    await tester.pump();

    expect(session.setCameraCalls, [true]);
  });

  testWidgets('the switch-camera control only appears once the camera is on', (
    tester,
  ) async {
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected),
      session: InertSession()..canFlipCamera = true,
    );
    expect(find.byTooltip('Switch camera'), findsNothing);

    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, cameraEnabled: true),
      session: InertSession()..canFlipCamera = true,
    );
    expect(find.byTooltip('Switch camera'), findsOneWidget);
  });

  testWidgets(
    'the switch-camera control stays hidden on a picker platform with '
    'only one camera',
    (tester) async {
      final session = InertSession()
        ..cameraNeedsSelection = true
        ..cameraDeviceList = const [
          CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
        ];
      await pumpControls(
        tester,
        const VoiceFlags(
          state: VoiceSessionState.connected,
          cameraEnabled: true,
        ),
        session: session,
      );

      expect(find.byTooltip('Switch camera'), findsNothing);
    },
  );

  testWidgets(
    'the switch-camera control appears on a picker platform with more '
    'than one camera',
    (tester) async {
      final session = InertSession()
        ..cameraNeedsSelection = true
        ..cameraDeviceList = const [
          CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
          CameraDevice(id: 'cam-2', label: 'USB webcam'),
        ];
      await pumpControls(
        tester,
        const VoiceFlags(
          state: VoiceSessionState.connected,
          cameraEnabled: true,
        ),
        session: session,
      );

      expect(find.byTooltip('Switch camera'), findsOneWidget);
    },
  );

  testWidgets('switching cameras flips directly on a platform with no picker', (
    tester,
  ) async {
    final session = InertSession()..canFlipCamera = true;
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, cameraEnabled: true),
      session: session,
    );

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();

    expect(session.cameraSwitchCalls, ['flip']);
    // No sheet: the mobile flip needs nobody to choose anything.
    expect(find.text('Choose a camera'), findsNothing);
  });

  testWidgets('switching cameras opens a picker on a platform that needs one', (
    tester,
  ) async {
    final session = InertSession()
      ..cameraNeedsSelection = true
      ..cameraDeviceList = const [
        CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
        CameraDevice(id: 'cam-2', label: 'USB webcam'),
      ];
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, cameraEnabled: true),
      session: session,
    );

    await tester.tap(find.byTooltip('Switch camera'));
    // pump, not pumpAndSettle: the switch button's pending spinner never settles while the sheet awaits a choice.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('USB webcam'), findsOneWidget);
    await tester.tap(find.text('USB webcam'));
    await tester.pumpAndSettle();

    expect(session.cameraSwitchCalls, ['select:cam-2']);
  });

  testWidgets('switching cameras selects the only device directly rather than '
      'opening a picker for a single entry', (tester) async {
    final session = InertSession()
      ..cameraNeedsSelection = true
      ..cameraDeviceList = const [
        CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
        CameraDevice(id: 'cam-2', label: 'USB webcam'),
      ];
    await pumpControls(
      tester,
      const VoiceFlags(state: VoiceSessionState.connected, cameraEnabled: true),
      session: session,
    );
    expect(find.byTooltip('Switch camera'), findsOneWidget);

    // A camera unplugged mid-call: the button still reflects the count at mount, but the next enumeration finds only one.
    session.cameraDeviceList = const [
      CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
    ];
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();

    expect(session.cameraSwitchCalls, ['select:cam-1']);
    expect(find.text('Choose a camera'), findsNothing);
  });
}
