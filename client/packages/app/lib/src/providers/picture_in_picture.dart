// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Android picture-in-picture for a call's video: when it may float, whether
/// it is floating, and what keeps the picture subscribed while it does.
///
/// The OS window is the same Flutter view, resized, so nothing is handed to
/// another engine and the track is never subscribed a second time. See
/// docs/decisions/0040-call-mini-player-and-pop-out.md, section 3.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'call_mini_player.dart';
import 'voice_controller.dart';
import 'voice_flags.dart';

/// The platform seam, overridable in tests.
final pictureInPictureChannelProvider = Provider<PictureInPictureChannel>((
  ref,
) {
  final channel = PictureInPictureChannel();
  ref.onDispose(channel.dispose);
  return channel;
});

/// Whether the OS is showing the app as its floating window right now.
final inPictureInPictureProvider = StateProvider<bool>((ref) => false);

/// A connected call with a remote share or camera: the same video-only rule
/// as the in-app mini-player, so an audio-only call never floats an empty box.
final pictureInPictureEligibleProvider = Provider<bool>((ref) {
  final connected = ref.watch(
    voiceFlagsProvider.select((f) => f.state == VoiceSessionState.connected),
  );
  return connected && ref.watch(miniPlayerFeedProvider) != null;
});

/// What the floating window shows: the feed, only while it is floating and
/// still eligible, so a call ending underneath it puts the app back.
final pictureInPictureFeedProvider = Provider<MiniPlayerFeed?>((ref) {
  if (!ref.watch(inPictureInPictureProvider)) return null;
  if (!ref.watch(pictureInPictureEligibleProvider)) return null;
  return ref.watch(miniPlayerFeedProvider);
});

/// Forwards declared video interest to the call, unless a hold or a pause is in force.
///
/// The canvas declares which tiles are on screen and the rest get
/// unsubscribed. Floating a call from the canvas would otherwise cull the very
/// track the window shows, so the hold declares no opinion, which keeps every
/// track, and the last real declaration is restored when the hold ends.
class VideoInterestRelay {
  VideoInterestRelay(this._apply);

  final void Function(Set<String>?) _apply;
  Set<String>? _declared;
  bool _held = false;

  void declare(Set<String>? tileKeys) {
    _declared = tileKeys;
    _reconcile();
  }

  void hold(bool held) {
    if (_held == held) return;
    _held = held;
    _reconcile();
  }

  void _reconcile() => _apply(_held ? null : _declared);
}

final videoInterestRelayProvider = Provider<VideoInterestRelay>((ref) {
  // The canvas declares null from its own dispose, which can run after the container is gone.
  var disposed = false;
  ref.onDispose(() => disposed = true);
  return VideoInterestRelay((keys) {
    if (disposed) return;
    ref.read(voiceControllerProvider.notifier).setVideoInterest(keys);
  });
});

/// Mounted by watching it from the app chrome: tells the platform when
/// floating is allowed, mirrors the window's state, and holds video interest
/// for as long as the window shows the feed.
final pictureInPictureHostProvider = Provider<void>((ref) {
  final channel = ref.watch(pictureInPictureChannelProvider);

  ref.listen<bool>(pictureInPictureEligibleProvider, (_, eligible) {
    unawaited(channel.setEligible(eligible));
  }, fireImmediately: true);

  final modes = channel.modeChanges.listen(
    (inPip) => ref.read(inPictureInPictureProvider.notifier).state = inPip,
  );
  ref.onDispose(modes.cancel);

  ref.listen<MiniPlayerFeed?>(pictureInPictureFeedProvider, (_, feed) {
    ref.read(videoInterestRelayProvider).hold(feed != null);
  });
});
