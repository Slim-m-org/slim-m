// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join cue's player sets GStreamer up on the UI thread on Linux. Started
/// in the same turn the call connected, it held the connecting screen up
/// while the call was already playing, for 55 s in a nested desktop repro.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';

/// Records whether the call stage had been built when each sound started.
class _ScreenAwarePlayer implements SoundPlayer {
  final startedOnCallStage = <bool>[];

  @override
  Future<void> play(NotificationSound sound) async {
    if (sound != NotificationSound.selfJoin) return;
    startedOnCallStage.add(find.text('call stage').evaluate().isNotEmpty);
  }

  @override
  Future<void> loop(NotificationSound sound) async {}

  @override
  Future<void> stopLoop() async {}

  @override
  Future<void> stopAll() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('the join cue starts once the call stage is on screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final player = _ScreenAwarePlayer();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 0,
            ),
          ),
        ),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        voiceControllerProvider.overrideWith(FakeVoiceController.new),
        notificationSoundControllerProvider.overrideWith(
          (ref) => NotificationSoundController(ref, player: player),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(notificationSoundControllerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Text(
              ref.watch(voiceControllerProvider).state ==
                      VoiceSessionState.connected
                  ? 'call stage'
                  : 'connecting',
            ),
          ),
        ),
      ),
    );
    final voice =
        container.read(voiceControllerProvider.notifier) as FakeVoiceController;

    voice.update((s) => s.copyWith(state: VoiceSessionState.connected));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(player.startedOnCallStage, [true]);
  });
}
