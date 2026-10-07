// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Resolves one user's public profile by id, for a caller that only holds an
/// author id (a message, a pin) rather than the full profile it rides on,
/// and needs the avatar cache key ([api.UserProfile.avatarUpdatedAt]) that
/// comes with it.
///
/// Fetched rather than taken from the member pane's already-loaded list: that
/// would make this file depend on a widget-layer provider. The batch cache
/// below means a given author is only ever fetched once per session
/// regardless of how many of their messages are on screen, and the ids of one
/// frame's rows share a single request.
///
/// [BatchProfilesController]'s map is left uncapped, deliberately rather than
/// by oversight (see `retention_policy.dart` for the sibling caches this was
/// weighed against): it is bounded by the number of distinct accounts this
/// viewer ever resolves an author for in one session, which tracks a
/// deployment's member count rather than its message count, and each entry
/// is a small profile record rather than a channel's worth of content. A
/// self-hosted community sized for this product does not put that anywhere
/// near the message-store or transcript-window concern this file's siblings
/// have.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../widgets/author_label.dart' show AuthorResolution;
import 'live_events.dart';
import 'providers.dart';
import 'rate_limit_retry.dart';

/// Null for a deleted or anonymized account (a 404), exactly like
/// [api.SlimmApi.listUsers] itself.
///
/// Answered from [batchProfilesControllerProvider], so the avatars and name
/// labels of a page of messages ask `GET /users?ids=` once between them
/// rather than `GET /users/{id}` once each, and an author already held is
/// never asked for again.
///
/// Re-resolves when its id is evicted (a [api.ProfileChanged] frame, or the
/// reconnect [BatchProfilesController.clear]), so a mounted avatar sees the
/// new picture. Listens for the held-to-evicted edge only: watching the
/// whole key would also re-run when the fetch itself lands.
final userProfileProvider = FutureProvider.autoDispose
    .family<api.UserProfile?, String>((ref, userId) {
      ref.listen(
        batchProfilesControllerProvider.select((m) => m.containsKey(userId)),
        (held, now) {
          if (held == true && !now) ref.invalidateSelf();
        },
      );
      return ref.read(batchProfilesControllerProvider.notifier).profile(userId);
    });

/// Resolves several ids in one round trip, for a caller that needs more than
/// one at a time (a report card needs its reporter and, for a user report,
/// its subject) and would otherwise cost one request per id.
///
/// A `Map` rather than a list of futures: an id present with a null value is
/// a confirmed miss (matching [api.SlimmApiUsers.listUsers]'s own "absent
/// means gone" contract), while an id absent from the map has simply not
/// been resolved yet, which is what lets a caller tell "still loading" apart
/// from "this account no longer exists".
///
/// Also the live cache a message row's author name is resolved against (see
/// `widgets/author_label.dart`): a [api.ProfileChanged] frame evicts the
/// renamed id so the next [resolve] re-asks for it, rather than carrying the
/// new name on the frame itself, which would make this map a second place
/// the value could be wrong.
class BatchProfilesController
    extends StateNotifier<Map<String, api.UserProfile?>> {
  BatchProfilesController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event is api.ProfileChanged && state.containsKey(event.userId)) {
        state = {...state}..remove(event.userId);
      }
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// Ids asked for and not yet answered, each with the callers waiting on it.
  final Map<String, Completer<api.UserProfile?>> _waiting = {};

  /// The subset of [_waiting] not yet sent: what the next flush batches.
  final Set<String> _unsent = {};
  bool _flushScheduled = false;

  /// [id]'s profile, from the cache or from the next batch.
  ///
  /// Every id asked for before the current frame's build pass ends rides one
  /// request (a microtask flush), and an id already in flight is joined, not
  /// asked again. Null for an account that is gone; throws what the request
  /// threw, leaving the id uncached so a later ask retries.
  Future<api.UserProfile?> profile(String id) {
    if (state.containsKey(id)) return Future.value(state[id]);
    final existing = _waiting[id];
    if (existing != null) return existing.future;
    final waiter = _waiting[id] = Completer<api.UserProfile?>();
    _unsent.add(id);
    if (!_flushScheduled) {
      _flushScheduled = true;
      scheduleMicrotask(_flush);
    }
    return waiter.future;
  }

  void _flush() {
    _flushScheduled = false;
    final ids = _unsent.toList(growable: false);
    _unsent.clear();
    if (ids.isNotEmpty) unawaited(_fetch(ids));
  }

  /// One request, split by the api layer only if it passes the server's cap,
  /// and retried after the server's own hint when it is rate limited.
  Future<void> _fetch(List<String> ids) async {
    try {
      final client = _ref.read(apiProvider);
      final found = await retryWhenRateLimited(
        () => client.listUsers(ids),
        wait: _ref.read(rateLimitWaitProvider),
      );
      final byId = {for (final profile in found) profile.id: profile};
      if (mounted) state = {...state, for (final id in ids) id: byId[id]};
      for (final id in ids) {
        _waiting.remove(id)?.complete(byId[id]);
      }
    } catch (error, stack) {
      for (final id in ids) {
        _waiting.remove(id)?.completeError(error, stack);
      }
    }
  }

  /// Fetches whichever of [ids] are not already known. Best-effort: a failed
  /// call leaves those ids unresolved rather than wrongly reading a network
  /// error as "account deleted".
  Future<void> resolve(Iterable<String> ids) async {
    final missing = ids.where((id) => !state.containsKey(id)).toSet();
    if (missing.isEmpty) return;
    await Future.wait(
      missing.map(
        (id) => profile(id).then<void>((_) {}, onError: (Object _) {}),
      ),
    );
  }

  /// Forgets every cached profile, for a session that may have missed
  /// [api.ProfileChanged] frames while disconnected: [SyncController.start]
  /// calls this on every (re)connect, since there is no cursor over renames
  /// to catch up from and asking fresh is always correct.
  void clear() => state = const {};

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Kept for the screen's lifetime (not `autoDispose`): a moderation queue
/// commonly repeats a reporter across several reports, and losing this
/// between rebuilds would re-fetch a profile the caller already has.
final batchProfilesControllerProvider =
    StateNotifierProvider<
      BatchProfilesController,
      Map<String, api.UserProfile?>
    >((ref) => BatchProfilesController(ref));

/// [authorId]'s own slice of [profiles], for a caller that wants to
/// `.select` [batchProfilesControllerProvider] rather than watch the whole
/// map: a row watching the map outright rebuilds on every other author's
/// resolve too, since [BatchProfilesController.resolve] replaces the map's
/// identity on every call. Selecting this record instead means the row only
/// rebuilds when its own author's entry actually changes - see
/// `widgets/author_label.dart`'s [authorLabelResolved], which consumes it.
AuthorResolution authorResolution(
  Map<String, api.UserProfile?> profiles,
  String authorId,
) => (present: profiles.containsKey(authorId), profile: profiles[authorId]);

/// Kicks off resolving whichever of [authorIds] this session does not
/// already have cached. Safe to call on every rebuild a message list
/// produces: [BatchProfilesController.resolve] itself skips ids it already
/// knows, so a screen that renders the same authors every frame costs one
/// scan of already-known ids, not a repeated fetch.
void resolveAuthorProfiles(WidgetRef ref, Iterable<String?> authorIds) {
  final ids = authorIds.whereType<String>().toSet();
  if (ids.isEmpty) return;
  unawaited(ref.read(batchProfilesControllerProvider.notifier).resolve(ids));
}
