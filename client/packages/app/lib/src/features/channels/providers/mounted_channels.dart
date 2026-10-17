// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channel ids are genuinely open right now - the piece
/// `retention_policy.dart` names as missing before its reachability rule can
/// drive a real sweep: `channelHistoryProvider` is per-channel and never
/// disposed, so its mere existence says nothing about whether a channel is
/// actually open, and nothing else in the app answers that question either.
///
/// `ChannelScreen` is the only widget that ever shows a channel's messages,
/// including a thread's ([ThreadScreen] reuses it wholesale), so registering
/// there in `State.initState`/`State.dispose`, and across a channel switch in
/// `State.didUpdateWidget`, covers every way a channel becomes, or stops
/// being, open.
///
/// Counted rather than a plain set: a route transition can hold two
/// [ChannelScreen]s naming the same channel for a moment (the outgoing and
/// incoming widget of a route animation), and the second one disposing must
/// not make the channel look closed while the first is still on screen.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A ref-counted registry of open channel ids.
class MountedChannels extends ChangeNotifier {
  final _counts = <String, int>{};

  /// Marks one more caller as showing [channelId].
  void register(String channelId) {
    _counts[channelId] = (_counts[channelId] ?? 0) + 1;
    notifyListeners();
  }

  /// Undoes one prior [register] call for [channelId]. Only drops it from
  /// [openChannelIds] once every caller that registered it has also
  /// unregistered.
  void unregister(String channelId) {
    final remaining = (_counts[channelId] ?? 0) - 1;
    if (remaining > 0) {
      _counts[channelId] = remaining;
    } else {
      _counts.remove(channelId);
    }
    notifyListeners();
  }

  /// Every channel id at least one [ChannelScreen] is showing right now.
  Set<String> get openChannelIds => _counts.keys.toSet();
}

/// One registry for the whole process. Deliberately never invalidated on
/// sign-out: it tracks widget mount state, not account state, and every
/// `ChannelScreen` from the previous session unmounts through the ordinary
/// routing teardown before a next session's screens ever mount.
final mountedChannelsProvider = Provider<MountedChannels>(
  (ref) => MountedChannels(),
);
