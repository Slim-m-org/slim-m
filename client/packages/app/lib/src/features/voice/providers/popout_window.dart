// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which feeds are popped out, each into its own OS window, and whether it can be.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../desktop/popout/popout_windowing.dart';
import '../../../providers/app_lock_controller.dart';
import 'call_mini_player.dart';
import 'share_watch.dart';
import 'voice_controller.dart';
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
final popOutLiveFeedsProvider = Provider<List<MiniPlayerFeed>>(
  (ref) => _liveFeeds(ref.watch),
);

final _connected = voiceControllerProvider.select(
  (s) => s.state == VoiceSessionState.connected,
);
final _stoppedShares = shareWatchProvider.select((s) => s.stopped);

List<MiniPlayerFeed> _liveFeeds(
  T Function<T>(ProviderListenable<T> provider) read,
) {
  final feeds = read(popOutFeedsProvider);
  if (feeds.isEmpty || read(appLockControllerProvider)) return const [];
  if (!read(_connected)) return const [];
  final stopped = read(_stoppedShares);
  final participants = read(voiceParticipantsAtOnce);
  return [
    for (final feed in feeds)
      if (!(feed.kind == FeedKind.screenShare &&
              stopped.contains(feed.identity)) &&
          _isLive(feed, participants))
        feed,
  ];
}

/// Runs [onChange] with the live popped-out feeds, now and at once on every
/// change of what decides them.
///
/// [popOutLiveFeedsProvider] is derived, so a listener on it waits for a
/// frame, and the main window draws none while it sits in the tray with a
/// pop-out still open.
void onPopOutLiveFeedsChanged(
  Ref ref,
  void Function(List<MiniPlayerFeed> feeds) onChange,
) {
  void sync() => onChange(_liveFeeds(ref.read));
  ref.listen(popOutFeedsProvider, (_, _) => sync());
  ref.listen(appLockControllerProvider, (_, _) => sync());
  ref.listen(_connected, (_, _) => sync());
  ref.listen(_stoppedShares, (_, _) => sync());
  ref.listen(voiceParticipantsAtOnce, (_, _) => sync());
  sync();
}
