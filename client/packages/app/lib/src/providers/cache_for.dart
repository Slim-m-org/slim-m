// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeping the most recent `autoDispose` provider values alive after their
/// last listener goes, rather than discarding them the instant nothing is
/// watching.
///
/// The problem it solves is switching channels: every avatar and every image
/// in the pane being left unmounts its watcher, so plain `autoDispose` threw
/// the bytes away and coming back refetched all of them over the network. The
/// symptom is a second of blank avatars on every switch, on content that
/// cannot have changed.
///
/// Removing `autoDispose` instead would fix that and trade it for a cache
/// that only grows: a long member list, or a channel full of images, would
/// hold every byte it ever fetched for the life of the process. That is the
/// wrong trade on a phone, and it is why the providers were written this way.
///
/// **Bounded by count, deliberately not by a timer.** The obvious shape is
/// `keepAlive()` plus a `Timer` that closes the link later, and it does work -
/// but a kept-alive provider does not dispose, so `onDispose` never runs to
/// cancel that timer, and every widget test touching an avatar then fails on
/// Flutter's pending-timer check (which runs before `tearDown`, so no cleanup
/// hook can save it). Sixty-eight tests failed that way before this was
/// rewritten. Counting entries also bounds memory directly, which is the
/// thing actually at risk, where a duration only bounds it indirectly.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the [capacity] most recently requested values alive, closing the
/// least recent when a new one arrives.
///
/// Closing a link does not discard anything by itself: it hands the provider
/// back to `autoDispose`, which drops it once nothing is watching. So an
/// evicted entry that is still on screen stays exactly as long as it is
/// needed.
class KeepAliveCache {
  KeepAliveCache(this.capacity);

  final int capacity;
  final _links = <Object, KeepAliveLink>{};

  /// Stops holding [key], so a failed value is not kept for later views.
  void release(Object key) => _links.remove(key)?.close();

  /// Registers this provider as one of the recent ones.
  ///
  /// Re-registering an existing key moves it to the most-recent end rather
  /// than adding a second link, so a value that keeps being asked for is the
  /// last thing evicted.
  void hold(Ref ref, Object key) {
    final existing = _links.remove(key);
    if (existing != null) {
      _links[key] = existing;
      return;
    }
    _links[key] = ref.keepAlive();
    ref.onDispose(() => _links.remove(key)?.close());
    while (_links.length > capacity) {
      final oldest = _links.keys.first;
      _links.remove(oldest)?.close();
    }
  }
}
