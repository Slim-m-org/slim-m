// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// YouTube's embed rules app-wide: one player plays at a time, and none
/// plays once the app leaves the screen.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/video/providers/embedded_video_player.dart';
import 'package:slimm_app/src/features/video/providers/video_playback_coordinator.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

import 'fake_video_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a player that starts pauses every other one, and only those', () {
    final coordinator = VideoPlaybackCoordinator();
    addTearDown(coordinator.dispose);
    final a = FakeVideoPlayer();
    final b = FakeVideoPlayer();
    coordinator
      ..attach(a)
      ..attach(b);

    b.emit(const VideoPlaying());
    expect((a.pauses, b.pauses), (1, 0));

    a.emit(const VideoPlaying());
    expect((a.pauses, b.pauses), (1, 1));
  });

  test('a detached player is left alone', () {
    final coordinator = VideoPlaybackCoordinator();
    addTearDown(coordinator.dispose);
    final a = FakeVideoPlayer();
    final b = FakeVideoPlayer();
    coordinator
      ..attach(a)
      ..attach(b)
      ..detach(a);

    b.emit(const VideoPlaying());
    coordinator.pauseAll();
    expect(a.pauses, 0);
    expect(b.pauses, 1);
  });

  for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
    test('every player pauses when the app goes ${state.name}', () {
      final container = ProviderContainer(
        overrides: [mobileLifecycleHostProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);
      final player = FakeVideoPlayer();
      container.read(videoPlaybackCoordinatorProvider).attach(player);
      final lifecycle = container.read(appLifecycleProvider.notifier);

      lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(player.pauses, 0, reason: 'an unfocused window is still seen');

      lifecycle.didChangeAppLifecycleState(state);
      expect(player.pauses, 1);
    });
  }
}
