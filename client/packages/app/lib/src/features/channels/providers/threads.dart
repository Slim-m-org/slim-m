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

import '../../../providers/live_events.dart';
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

/// The thread docked beside each channel, keyed by the channel it was opened beside.
typedef DockedThreads = Map<String?, String>;

/// The threads docked beside the transcript; each channel remembers its own,
/// so switching away hides it and coming back shows it again. The single
/// source of truth for the desktop side-pane presentation, mirroring
/// [canvasOpenProvider]/[memberPaneVisibleProvider]: at expanded widths an
/// in-app "open thread" sets this and the shell docks a pane, so the parent
/// transcript stays visible (UX1). At compact widths, and for a cold deep link
/// or reload, the `/thread/:id` route and its modal are used instead - so this
/// is deliberately not URL-backed, and a reload closes a docked thread back to
/// its channel rather than restoring the pane.
final dockedThreadsProvider = StateProvider<DockedThreads>((ref) => const {});

/// The thread docked beside [channelId], or null.
String? dockedThreadBeside(DockedThreads docked, String? channelId) =>
    docked[channelId];

/// Closes the thread docked beside [besideChannelId], keeping every other channel's.
void closeDockedThread(
  StateController<DockedThreads> docked,
  String? besideChannelId,
) => docked.state = {...docked.state}..remove(besideChannelId);

/// Bumped each time the user asks for a thread that is already docked, so the
/// pane's composer takes focus again; a new thread focuses itself on mount.
final threadComposerFocusRequestProvider = StateProvider<int>((ref) => 0);

/// Docks [threadId] in the side pane beside [besideChannelId]. Asking for the
/// thread already open there moves the caret back into its composer instead.
void dockThread(
  ProviderContainer container,
  String threadId, {
  required String? besideChannelId,
}) {
  final docked = container.read(dockedThreadsProvider.notifier);
  if (docked.state[besideChannelId] == threadId) {
    container.read(threadComposerFocusRequestProvider.notifier).state++;
  } else {
    docked.state = {...docked.state, besideChannelId: threadId};
  }
}

/// What a thread's own channel id hangs off, for a thread panel opened cold
/// - a deep link, a reload, or a notification - that never went through
/// [openThreadFromMessage] on this device and so never learned its parent
/// any other way. `autoDispose` and fetched fresh on every watch.
///
/// The ids never change once a thread exists, but the parent's text can be
/// edited or deleted while the thread is open, so either event for it reads
/// the parent again. The parent channel's own name is left to the next open.
final threadParentProvider = FutureProvider.autoDispose
    .family<api.ThreadParent, String>((ref, channelId) async {
      String? parentId;
      // Subscribed before the fetch: a provider disposed during it takes no new listener.
      final changes = ref
          .watch(liveEventsProvider)
          .where(
            (e) =>
                parentId != null &&
                ((e is api.MessageDeleted && e.messageId == parentId) ||
                    (e is api.MessageEdited && e.message.id == parentId)),
          )
          .listen((_) => ref.invalidateSelf());
      ref.onDispose(changes.cancel);
      final parent = await ref.watch(apiProvider).getThreadParent(channelId);
      parentId = parent.parentMessageId;
      return parent;
    });

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
