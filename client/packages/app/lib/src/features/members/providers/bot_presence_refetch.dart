// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a per-channel bot list honest about which bots are online.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import '../../../providers/sync_controller.dart';

/// Refetches the provider when a bot in its result changes presence, when
/// one did so while the fetch was in flight, and when the socket comes back
/// after a gap. Call [BotPresenceWatch.loaded] with the bot ids once fetched.
BotPresenceWatch watchBotPresence(
  Ref ref, {
  bool Function(api.ServerEvent event)? alsoWhen,
}) {
  final watch = BotPresenceWatch._();
  final changes = ref.read(liveEventsProvider).listen((event) {
    if (alsoWhen != null && alsoWhen(event)) ref.invalidateSelf();
    if (event is api.PresenceChanged) watch._onPresence(event.userId, ref);
  });
  ref.onDispose(changes.cancel);
  ref.listen(syncControllerProvider, (previous, next) {
    if (next == SyncStatus.live && previous != SyncStatus.live) {
      ref.invalidateSelf();
    }
  });
  return watch;
}

class BotPresenceWatch {
  BotPresenceWatch._();

  final _bots = <String>{};
  final _seenWhileLoading = <String>{};
  bool _isLoaded = false;

  void _onPresence(String userId, Ref ref) {
    if (!_isLoaded) {
      _seenWhileLoading.add(userId);
    } else if (_bots.contains(userId)) {
      ref.invalidateSelf();
    }
  }

  /// Records the bots in the fetched result; a presence change that landed
  /// before this for one of them means the result may already be stale.
  void loaded(Ref ref, Iterable<String> botIds) {
    _bots.addAll(botIds);
    _isLoaded = true;
    if (_seenWhileLoading.any(_bots.contains)) ref.invalidateSelf();
  }
}
