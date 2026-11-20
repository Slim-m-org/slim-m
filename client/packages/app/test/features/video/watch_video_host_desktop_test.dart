// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A YouTube watch party on desktop plays on the call stage through the shared
/// desktop player, never in the side panel, and lets go of it when the stage does.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/video/providers/desktop_video.dart';
import 'package:slimm_app/src/features/video/providers/video_host_capability.dart';
import 'package:slimm_app/src/features/video/providers/watch_video_host.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'fake_video_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the party plays on the stage and closes the player when released',
    () async {
      SharedPreferences.setMockInitialValues({});
      final player = FakeVideoPlayer();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWith(
            (ref) => SharedPreferences.getInstance(),
          ),
          desktopVideoPlayerFactoryProvider.overrideWithValue(() => player),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(desktopVideoProvider, (_, _) {});
      addTearDown(sub.close);

      final factory = container.read(
        watchVideoFactoryProvider(VideoHostKind.desktop),
      )!;
      final handle = factory(
        container,
        videoId: 'dQw4w9WgXcQ',
        start: const Duration(seconds: 30),
        title: 'A talk',
        onShowFullscreen: (_, _) {},
        onHideFullscreen: () {},
      );

      expect(handle.view, isNull, reason: 'the stage draws the shared player');
      expect(handle.player, same(player));
      expect(player.loads.single.id, 'dQw4w9WgXcQ');
      expect(player.loads.single.start, const Duration(seconds: 30));
      final playing = container.read(desktopVideoProvider);
      expect(playing?.docked, isFalse, reason: 'a party is never in the panel');

      await handle.load('aqz-KE-bpKQ', Duration.zero, 'Next');
      expect(player.loads.last.id, 'aqz-KE-bpKQ');

      await handle.release();
      expect(container.read(desktopVideoProvider), isNull);
    },
  );

  test(
    'releasing leaves alone a video someone opened in a message since',
    () async {
      SharedPreferences.setMockInitialValues({});
      final player = FakeVideoPlayer();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWith(
            (ref) => SharedPreferences.getInstance(),
          ),
          desktopVideoPlayerFactoryProvider.overrideWithValue(() => player),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(desktopVideoProvider, (_, _) {});
      addTearDown(sub.close);

      final handle =
          container.read(watchVideoFactoryProvider(VideoHostKind.desktop))!(
            container,
            videoId: 'dQw4w9WgXcQ',
            start: Duration.zero,
            title: 'A talk',
            onShowFullscreen: (_, _) {},
            onHideFullscreen: () {},
          );
      final message = Object();
      container
          .read(desktopVideoProvider.notifier)
          .playIn(
            message,
            'https://youtu.be/aqz-KE-bpKQ',
            _preview('aqz-KE-bpKQ'),
          );

      await handle.release();
      expect(container.read(desktopVideoProvider)?.owner, same(message));
    },
  );
}

LinkPreview _preview(String id) => LinkPreview(
  url: 'https://youtu.be/$id',
  videoProvider: LinkPreviewVideoProvider.youtube,
  videoId: id,
);
