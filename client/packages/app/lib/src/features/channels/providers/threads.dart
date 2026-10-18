// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening a thread from a message.
///
/// A thread is an ordinary channel once opened (`GET /channels/{id}/messages`
/// and `POST` to send both work on it unchanged, exactly like a DM), so this
/// file does not give threads a parallel data model either - see
/// `providers/dms.dart`'s own doc comment for the precedent this follows.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// The local channel row's `name` for a thread: empty, mirroring the
/// server's own `Store::open_thread`, which inserts `''` for the identical
/// reason (`channel_screen.dart`'s `hashChannelName`/`ChannelStartHeader`
/// both special-case an empty name to drop the "#name" clause rather than
/// substitute one). `ThreadScreen`'s own AppBar title never reads this
/// field - it is `threadParentProvider`'s job - so nothing here is ever
/// shown as-is; this exists only so the composer and transcript hints see
/// the same "no name" signal a thread's own server row would answer with.
/// A non-empty placeholder here was a real, if invisible, bug: the composer
/// hint would have rendered "Message #Thread" instead of "Message" for
/// every warm-opened thread, the exact dangling-hash failure this constant
/// exists to avoid, just with the wrong value.
const String threadChannelName = '';

/// The thread docked beside the transcript right now, as its channel id, or
/// null for none. The single source of truth for the desktop side-pane
/// presentation, mirroring [canvasOpenProvider]/[memberPaneVisibleProvider]:
/// at expanded widths an in-app "open thread" sets this and the shell docks a
/// pane, so the parent transcript stays visible (UX1). At compact widths, and
/// for a cold deep link or reload, the `/thread/:id` route and its modal are
/// used instead - so this is deliberately not URL-backed, and a reload closes
/// a docked thread back to its channel rather than restoring the pane.
final openThreadProvider = StateProvider<String?>((ref) => null);

/// Bumped each time the user asks for a thread that is already docked, so the
/// pane's composer takes focus again; a new thread focuses itself on mount.
final threadComposerFocusRequestProvider = StateProvider<int>((ref) => 0);

/// Docks [threadId] in the side pane. Asking for the thread already open
/// moves the caret back into its composer instead of doing nothing.
void dockThread(ProviderContainer container, String threadId) {
  final open = container.read(openThreadProvider.notifier);
  if (open.state == threadId) {
    container.read(threadComposerFocusRequestProvider.notifier).state++;
  } else {
    open.state = threadId;
  }
}

/// What a thread's own channel id hangs off, for a thread panel opened cold
/// - a deep link, a reload, or a notification - that never went through
/// [openThreadFromMessage] on this device and so never learned its parent
/// any other way. `autoDispose` and fetched fresh on every watch, the same
/// shape `channelPermissionsProvider.dart` already uses: the answer is
/// immutable once a thread exists (a channel id and a message id, neither
/// of which can change), so there is nothing to invalidate - the one
/// exception is the parent channel's own name, which can be renamed after
/// the fact, an accepted staleness window closed by the next screen open
/// rather than a live event.
final threadParentProvider = FutureProvider.autoDispose
    .family<api.ThreadParent, String>(
      (ref, channelId) => ref.watch(apiProvider).getThreadParent(channelId),
    );

/// Every live thread hanging off a message in [channelId], newest activity
/// first - the listing docs/IMPLIED-GAPS.md named as missing entirely:
/// before this, the only way to find a thread was from the message it hangs
/// off.
///
/// `autoDispose`, fetched fresh whenever the threads sheet opens. No live
/// event wires into this, deliberately: unlike the message transcript this
/// is a low-traffic, occasionally-opened surface, so a plain re-fetch on
/// reopen (or `ref.invalidate` from a Retry button) is simpler than
/// teaching `ThreadUpdated` to also patch a list nobody is usually looking
/// at while it fires.
final threadsListProvider = FutureProvider.autoDispose
    .family<List<api.ThreadListItem>, String>(
      (ref, channelId) => ref.watch(apiProvider).listThreads(channelId),
    );

/// Opens (or reuses) the thread hanging off [messageId] in [channelId], and
/// gets it into the local store with an initial page of whatever it already
/// holds.
///
/// Unlike [openDirectMessage] (`providers/dms.dart`), this always fetches a
/// backfill page: a DM either has no history yet (freshly opened, nothing to
/// fetch) or was already synced through the ordinary periodic channel
/// refresh, since `GET /dms` lists it. A thread is excluded from every such
/// listing by design (`docs/decisions/0005-threads.md`), so re-opening one
/// that already has messages is the only chance this client gets to learn
/// about them before a live event happens to arrive.
///
/// Takes a [ProviderContainer] rather than a [WidgetRef], the same reason
/// [openDirectMessage] does: the message row that starts this can be
/// disposed (its menu closed) before the request answers.
Future<String> openThreadFromMessage(
  ProviderContainer container,
  String channelId,
  String messageId,
) async {
  final client = container.read(apiProvider);
  final thread = await client.openThread(
    channelId: channelId,
    messageId: messageId,
  );
  final store = await container.read(storeProvider.future);
  await store.upsertChannels([
    api.Channel(
      id: thread.id,
      name: threadChannelName,
      kind: thread.kind,
      createdAt: thread.createdAt,
      parentMessageId: thread.parentMessageId,
    ),
  ]);
  try {
    final recent = await client.listMessages(thread.id, limit: 50);
    await store.applyMessages(recent);
  } on api.ApiException catch (error, stack) {
    api.reportFailure(
      api.LogTag.ui,
      'load the messages of a thread',
      error,
      stack,
    );
    // Best effort: the transcript's own live socket or a later reopen corrects it.
  }
  return thread.id;
}
