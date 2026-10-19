// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A popped-out feed has a window of its own, so it stays subscribed while the
/// main window is minimised or unfocused, and is released when the pop-out closes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/popout_window.dart';
import 'package:slimm_app/src/features/voice/providers/video_interest_relay.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _feed = (identity: 'u-ada', name: 'Ada', kind: FeedKind.screenShare);

class _Call extends VoiceController {
  _Call(super.ref, FakeSession session) : super(session: session) {
    state = const VoiceState(
      channelId: 'c-main',
      state: VoiceSessionState.connected,
      participants: [_ada],
    );
  }
}

void main() {
  setUp(TestWidgetsFlutterBinding.ensureInitialized);

  Future<(ProviderContainer, FakeSession)> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.pause_video_when_unfocused': true,
    });
    final session = FakeSession();
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        voiceControllerProvider.overrideWith((ref) => _Call(ref, session)),
        pauseOnUnfocusedAppliesProvider.overrideWithValue(true),
      ],
    );
    container.read(voiceSettingsControllerProvider);
    await tester.runAsync(() => container.read(preferencesProvider.future));
    container.read(videoInterestHostProvider);
    container.read(popOutFeedProvider.notifier).state = _feed;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const PopOutWindowView(feed: _feed),
        ),
      ),
    );
    await tester.pump();
    return (container, session);
  }

  for (final away in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    testWidgets('the pop-out keeps its feed while the main window is $away', (
      tester,
    ) async {
      final (container, session) = await pump(tester);
      container.read(videoInterestRelayProvider).refresh();
      expect(session.videoInterests.last, {'screen:u-ada'});

      container
          .read(appLifecycleProvider.notifier)
          .didChangeAppLifecycleState(away);
      await tester.pump();
      expect(session.videoInterests.last, {'screen:u-ada'});

      container.read(popOutFeedProvider.notifier).state = null;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      expect(session.videoInterests.last, isEmpty);
      await tester.pumpAndSettle();
      container.dispose();
    });
  }
}
