// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this viewer can play the watch party's title themselves, and if
/// not, the one line that says which test failed and what fixes it.
///
/// Three independent tests, in the order decision 0050 section 3 lists them:
/// a verified link, a client that can reach the media server, and an account
/// whose library holds the item. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'package:slimm_api/api.dart' as api;

/// The first test a viewer fails, in the order the tests run.
enum DirectPlayBlock { noLink, unverifiedLink, unreachable, cannotSee }

/// What each failed test tells the viewer; the viewer is always on the shared stream meanwhile.
String directPlayBlockLine(DirectPlayBlock block) => switch (block) {
  DirectPlayBlock.noLink =>
    'Watching the shared stream. Link a Jellyfin account to watch at source quality.',
  DirectPlayBlock.unverifiedLink =>
    'Watching the shared stream. Your Jellyfin link is not verified yet.',
  DirectPlayBlock.unreachable =>
    'Watching the shared stream. This device cannot reach Jellyfin directly.',
  DirectPlayBlock.cannotSee =>
    'Watching the shared stream. Your Jellyfin account cannot see this title.',
};

/// What the viewer's own device found out about the media server.
class DirectPlayProbe {
  const DirectPlayProbe({this.reachable, this.canSeeItem});

  /// Null until the address has been tried.
  final bool? reachable;

  /// Null until the viewer has signed in and the item has been looked up.
  final bool? canSeeItem;
}

/// The link test, which the bot's offer answers on its own.
DirectPlayBlock? linkBlock(api.WatchDirectPlay offer, String userId) {
  if (offer.verifiedUserIds.contains(userId)) return null;
  return offer.unverifiedUserIds.contains(userId)
      ? DirectPlayBlock.unverifiedLink
      : DirectPlayBlock.noLink;
}

/// The first failed test, or null when the viewer may be offered direct play.
///
/// A test whose answer is not in yet does not fail: the viewer is offered the
/// choice and told at the point it matters, rather than blocked on a guess.
DirectPlayBlock? firstBlock({
  required api.WatchDirectPlay offer,
  required String userId,
  required DirectPlayProbe probe,
}) {
  final link = linkBlock(offer, userId);
  if (link != null) return link;
  if (probe.reachable == false) return DirectPlayBlock.unreachable;
  if (probe.canSeeItem == false) return DirectPlayBlock.cannotSee;
  return null;
}
