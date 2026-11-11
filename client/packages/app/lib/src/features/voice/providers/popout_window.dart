// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which feeds are popped out, each into its own OS window, and whether it can be.
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

/// What the user asked to pop out, one entry per feed; any may have ended
/// since, see [popOutLiveFeedsProvider].
class PopOutFeeds extends Notifier<List<MiniPlayerFeed>> {
  @override
  List<MiniPlayerFeed> build() => const [];

  /// Asks for [feed]'s window; a feed already out keeps the one it has.
  void open(MiniPlayerFeed feed) {
    if (state.any((f) => _sameFeed(f, feed))) return;
    state = [...state, feed];
  }

  void close(MiniPlayerFeed feed) => state = [
    for (final f in state)
      if (!_sameFeed(f, feed)) f,
  ];

  void keepOnly(List<MiniPlayerFeed> feeds) {
    if (feeds.length != state.length) state = feeds;
  }
}

bool _sameFeed(MiniPlayerFeed a, MiniPlayerFeed b) =>
    a.identity == b.identity && a.kind == b.kind;

final popOutFeedsProvider = NotifierProvider<PopOutFeeds, List<MiniPlayerFeed>>(
  PopOutFeeds.new,
);

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

/// The requested feeds that are still being published while the call is
/// connected and the app is unlocked; a feed missing here has its window closed.
///
/// The windows are separate views outside the lock gate, so a lock closes them all.
final popOutLiveFeedsProvider = Provider<List<MiniPlayerFeed>>((ref) {
  final feeds = ref.watch(popOutFeedsProvider);
  if (feeds.isEmpty || ref.watch(appLockControllerProvider)) return const [];
  final connected = ref.watch(
    voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
  );
  if (!connected) return const [];
  final stopped = ref.watch(shareWatchProvider.select((s) => s.stopped));
  final participants = ref.watch(voiceParticipantsProvider);
  return [
    for (final feed in feeds)
      if (!(feed.kind == FeedKind.screenShare &&
              stopped.contains(feed.identity)) &&
          _isLive(feed, participants))
        feed,
  ];
});
