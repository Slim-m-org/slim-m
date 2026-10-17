// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which feed is popped out into its own OS window, and whether it can be.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../desktop/popout/popout_windowing.dart';
import '../../../providers/app_lock_controller.dart';
import 'call_mini_player.dart';
import 'share_watch.dart';
import 'voice_flags.dart';

/// Null hides every pop-out control: web, and any desktop build without the
/// windowing flag. Tests override it with a fake.
final popOutWindowFactoryProvider = Provider<PopOutWindowFactory?>(
  (ref) => nativePopOutWindowFactory(),
);

final popOutSupportedProvider = Provider<bool>(
  (ref) => ref.watch(popOutWindowFactoryProvider) != null,
);

/// What the user asked to pop out; it may have ended since, see
/// [popOutLiveFeedProvider].
final popOutFeedProvider = StateProvider<MiniPlayerFeed?>((ref) => null);

bool _isLive(MiniPlayerFeed feed, List<VoiceParticipant> participants) {
  for (final p in participants) {
    if (p.identity != feed.identity) continue;
    return switch (feed.kind) {
      FeedKind.screenShare => p.isScreenSharing,
      FeedKind.camera => p.isCameraOn,
    };
  }
  return false;
}

/// The requested feed while the call is connected and the feed is still being
/// published and the app is unlocked; null otherwise, which closes the window.
///
/// The window is a separate view outside the lock gate, so a lock must close it.
final popOutLiveFeedProvider = Provider<MiniPlayerFeed?>((ref) {
  final feed = ref.watch(popOutFeedProvider);
  if (feed == null || ref.watch(appLockControllerProvider)) return null;
  final connected = ref.watch(
    voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
  );
  if (!connected) return null;
  final stopped = ref.watch(shareWatchProvider.select((s) => s.stopped));
  if (feed.kind == FeedKind.screenShare && stopped.contains(feed.identity)) {
    return null;
  }
  return _isLive(feed, ref.watch(voiceParticipantsProvider)) ? feed : null;
});
