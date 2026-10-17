// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's effective permission bitmask in one channel: the per-channel
/// sibling of `myPermissionsProvider`'s deployment-wide bitmask.
///
/// See docs/decisions/0011-per-channel-permissions.md for why this exists -
/// seven client sites gated an action on the wrong bitmask because nothing
/// until now let a caller ask the right one. Invalidation lives beside
/// `roleChangeWatcherProvider` in `admin_providers.dart`, extending that
/// listener rather than opening a second one on the same live-event stream.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

/// The caller's raw effective bitmask in [channelId], fetched fresh on every
/// watch the same way `invitesProvider`/`rolesProvider` are: nothing here is
/// long-lived state, so a screen refetches on entry. Always calls the
/// network route uniformly, for every channel id, whether or not that id
/// also happens to be present in a locally cached `Channel.permissions` -
/// one source of truth for this fact rather than two that could disagree.
final channelPermissionsProvider = FutureProvider.autoDispose
    .family<int, String>(
      (ref, channelId) =>
          ref.watch(apiProvider).getChannelPermissions(channelId),
    );

/// The plain `int` every call site actually wants: 0 while
/// [channelPermissionsProvider] is loading or failed, the same "show nothing
/// until proven otherwise" convention `myPermissionsProvider` already
/// applies to `meProvider`. Read this in `build()`, never `ref.read` it once
/// in a callback - a cold `autoDispose` `FutureProvider` read that way
/// renders permanently empty.
final myChannelPermissionsProvider = Provider.family<int, String>(
  (ref, channelId) =>
      ref.watch(channelPermissionsProvider(channelId)).valueOrNull ?? 0,
);

/// Every channel the caller can currently see, each carrying its own
/// [Channel.permissions] - the list-wide sibling of
/// [channelPermissionsProvider]'s single-channel question, for "which of my
/// channels can I do X in" rather than "what can I do in this one open
/// channel". Fetched fresh through `GET /channels` on every watch, matching
/// `rolesProvider`/`invitesProvider`; excludes DMs and threads, which never
/// appear in that response. Empty while loading or on error.
final myVisibleChannelsProvider = FutureProvider.autoDispose<List<Channel>>(
  (ref) => ref.watch(apiProvider).listChannels(),
);
