// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [SyncController]'s reset half: refetching a scope the server told the
/// client to discard.
///
/// Split out of `sync_controller.dart`, which sat at the 500-line ceiling.
part of 'sync_controller.dart';

extension SyncControllerReset on SyncController {
  /// Drops a scope's cached messages and both its cursors, then refetches the
  /// newest page.
  ///
  /// [MessageStore.resetChannel] clears the op cursor to null as well as
  /// rewinding the message one, so the next catch-up adopts a fresh head
  /// rather than asking from a seq the server may have swept past.
  Future<void> _resetScope(
    int generation,
    SlimmApi api,
    MessageStore store,
    String channelId,
  ) async {
    await store.resetChannel(channelId);
    final fresh = await retryWhenRateLimited(
      () => api.listMessages(channelId, limit: 50),
      wait: _ref.read(rateLimitWaitProvider),
    );
    if (generation != _generation) return;
    await store.applyMessages(fresh);
    _ref.read(messageExtrasProvider.notifier).applyMessages(fresh);
  }
}
