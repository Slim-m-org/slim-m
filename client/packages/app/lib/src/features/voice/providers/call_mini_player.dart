// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the call mini-player rests, and which feed it carries.
///
/// The corner is session state, not persisted: the player is a transient view
/// and a stale corner from last week would only ever surprise.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_flags.dart';

enum MiniPlayerCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Bottom-right, where Discord parks its own, and away from the left edge a
/// drawer swipe starts from.
final miniPlayerCornerProvider = StateProvider<MiniPlayerCorner>(
  (ref) => MiniPlayerCorner.bottomRight,
);

enum FeedKind { screenShare, camera }

/// The feed the mini-player shows: what [identity] is publishing.
typedef MiniPlayerFeed = ({String identity, String name, FeedKind kind});

/// A remote screen share first, then a remote camera; null when there is
/// nothing to look at, which is also when the player stays away.
///
/// The local participant is excluded: previewing your own share inside the app
/// that is sharing it is a hall of mirrors. There is no per-user "watching"
/// state to consult, so this is the first remote publisher in roster order.
MiniPlayerFeed? pickMiniPlayerFeed(List<VoiceParticipant> participants) {
  for (final p in participants) {
    if (!p.isLocal && p.isScreenSharing) {
      return (identity: p.identity, name: p.name, kind: FeedKind.screenShare);
    }
  }
  for (final p in participants) {
    if (!p.isLocal && p.isCameraOn) {
      return (identity: p.identity, name: p.name, kind: FeedKind.camera);
    }
  }
  return null;
}

/// The feed for the current roster; records compare by value, so a listener
/// only rebuilds when the pick itself changes.
final miniPlayerFeedProvider = Provider<MiniPlayerFeed?>(
  (ref) => pickMiniPlayerFeed(ref.watch(voiceParticipantsProvider)),
);

/// Space the player must never enter, measured in from each edge of the pane
/// it floats over.
class MiniPlayerInsets {
  const MiniPlayerInsets({
    required this.top,
    required this.bottom,
    this.side = 12,
  });

  final double top;
  final double bottom;
  final double side;
}

/// The top-left of the player when resting in [corner].
Offset cornerOrigin(
  MiniPlayerCorner corner,
  Size region,
  Size player,
  MiniPlayerInsets insets,
) {
  final left = insets.side;
  final right = region.width - player.width - insets.side;
  final top = insets.top;
  final bottom = region.height - player.height - insets.bottom;
  return switch (corner) {
    MiniPlayerCorner.topLeft => Offset(left, top),
    MiniPlayerCorner.topRight => Offset(right, top),
    MiniPlayerCorner.bottomLeft => Offset(left, bottom),
    MiniPlayerCorner.bottomRight => Offset(right, bottom),
  };
}

/// The corner nearest to where [origin] would land after coasting [velocity]
/// for [coast], so a flick throws the player rather than dropping it.
MiniPlayerCorner nearestCorner(
  Offset origin,
  Offset velocity,
  Size region,
  Size player,
  MiniPlayerInsets insets, {
  Duration coast = const Duration(milliseconds: 120),
}) {
  final landing = origin + velocity * (coast.inMilliseconds / 1000);
  var best = MiniPlayerCorner.bottomRight;
  var bestDistance = double.infinity;
  for (final corner in MiniPlayerCorner.values) {
    final d = (cornerOrigin(corner, region, player, insets) - landing)
        .distanceSquared;
    if (d < bestDistance) {
      best = corner;
      bestDistance = d;
    }
  }
  return best;
}
