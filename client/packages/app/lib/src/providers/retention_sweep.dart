// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bounding the two caches `retention_policy.dart` names as unbounded (CD2,
/// the local store's message rows, and CS4, `message_extras.dart`'s map).
///
/// Both are only safe to prune against a genuine reachability answer, and
/// [MountedChannels] is what finally supplies one: a message belongs to a
/// channel nobody has open right now, or it sits among a still-open
/// channel's newest [channelWindowCeiling] rows and must survive.
/// `channel_history.dart` already never lets a channel's live window grow
/// past that same ceiling, so once the store holds no more than the ceiling
/// for any channel, "every row this channel still has" and "every row some
/// window could ever show" are the same set - which is exactly what lets
/// [runRetentionSweep] answer message_extras' reachability question by
/// re-reading the store right after capping it, rather than maintaining a
/// second, parallel notion of what is current.
///
/// Search (now cross-channel; see `http::search`'s `/search/messages`),
/// pins and the command palette's message results all render straight off
/// the `Message`/`MessageDto` the server already returned - author
/// resolution goes through `resolveAuthorProfiles`, reactions arrive
/// pre-embedded via `with_reactions` - and never read or write
/// [messageExtrasProvider], regardless of which channel a hit belongs to.
/// Only paging a channel's own history (`channel_history.dart`,
/// `channel_screen.dart`) and acting in the open channel's composer
/// (`message_actions.dart`, `forward_message.dart`,
/// `poll_composer_sheet.dart`) ever call `applyMessage(s)`, and both only
/// ever do that for the channel presently open. That is what makes dropping
/// every extras entry outside the open channels' rows safe, not merely
/// convenient.
///
/// **Trigger: periodic**, chosen over app-resume or post-sync. CD2's own
/// growth comes from `channel_history.dart` paging a channel's history
/// backwards while it sits open - a long scrollback session run without ever
/// backgrounding the app or losing the socket would never sweep under
/// either of those two triggers, since neither has any reason to coincide
/// with paging. A repeating timer, the same shape the server's own
/// background sweeps already use for its own message retention (see
/// `lib.rs::run`), bounds that case regardless of what else the session
/// happens to be doing.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import 'message_extras.dart';
import '../features/channels/providers/mounted_channels.dart';
import 'providers.dart';
import 'retention_policy.dart';

/// How often a live session sweeps. Generous on purpose: this bounds a
/// durability concern profiling has not shown to be urgent (see
/// `retention_policy.dart`'s own note on the 884 KB measurement), not a
/// problem being actively worked around.
const retentionSweepInterval = Duration(minutes: 10);

/// Caps [store] to [channelWindowCeiling] rows per channel, then drops every
/// [MessageExtrasController] entry that capping left unreachable for
/// [openChannelIds].
///
/// Order matters: extras' reachability answer is read off the store after
/// it has been capped, not before, which is what lets it be answered with a
/// plain read rather than re-deriving the same "newest ceiling rows" logic a
/// second time.
///
/// [ceiling] defaults to the real policy; a test names a smaller one so its
/// fixtures do not need thousands of rows to see a prune take effect.
Future<void> runRetentionSweep(
  MessageStore store,
  MessageExtrasController extras,
  Set<String> openChannelIds, {
  int ceiling = channelWindowCeiling,
}) async {
  await store.pruneToRetentionCeiling(ceiling);
  final reachable = await store.reachableMessageIds(openChannelIds);
  extras.retain(reachable);
}

/// Runs [runRetentionSweep] every [retentionSweepInterval] for as long as
/// something keeps [retentionSweepControllerProvider] alive.
class RetentionSweepController {
  RetentionSweepController(this._ref) {
    _timer = Timer.periodic(retentionSweepInterval, (_) => _sweep());
  }

  final Ref _ref;
  late final Timer _timer;

  Future<void> _sweep() async {
    try {
      final store = await _ref.read(storeProvider.future);
      final extras = _ref.read(messageExtrasProvider.notifier);
      final openChannelIds = _ref.read(mountedChannelsProvider).openChannelIds;
      await runRetentionSweep(store, extras, openChannelIds);
    } catch (_) {
      // Best-effort: a store not ready yet, or briefly gone mid sign-out, just tries again next tick.
    }
  }

  void dispose() => _timer.cancel();
}

/// Forces [RetentionSweepController] into existence for the session - see
/// `home_shell.dart`, the one place that watches this. Nothing here reads
/// its own state; the timer it starts is the entire point.
final retentionSweepControllerProvider =
    Provider.autoDispose<RetentionSweepController>((ref) {
      final controller = RetentionSweepController(ref);
      ref.onDispose(controller.dispose);
      return controller;
    });
