// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The deployment's member roster and live presence for it.
///
/// Split out of `widgets/member_pane.dart` to separate the data (this file)
/// from its rendering; most of this file's callers only ever wanted
/// [membersProvider], never anything about how the pane itself draws a row.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'live_events.dart';
import 'presence_controller.dart';
import 'providers.dart';
import 'sync_controller.dart';

/// The server's own per-page ceiling (`MEMBERS_MAX_LIMIT` in
/// `crates/slimm-server/src/http/users.rs`), requested explicitly on every
/// page: the server's default without an explicit limit is a much smaller
/// 50, and asking for the max up front costs the fewest round trips.
const _memberPageLimit = 200;

/// A defensive stop on how many pages [membersProvider] will follow. Pages
/// this size in the low hundreds already cover the largest deployment this
/// product targets, so reaching it means the server broke its own "a page
/// shorter than requested is the last one" contract; paging then stops and
/// returns whatever was already fetched, silently short of the full roster,
/// rather than looping forever.
const _maxMemberPages = 500;

/// How long a burst of roster events settles before the roster is refetched.
const memberRosterRefetchDelay = Duration(milliseconds: 400);

/// The deployment's members, real endpoint, real data, paged to completion.
/// A single request never returns more than [_memberPageLimit] rows, so
/// anything past the first page needs a follow-up keyed on the last id
/// already seen; a page shorter than [_memberPageLimit] is the contract's
/// own signal that there is no next one.
final membersProvider = FutureProvider.autoDispose<List<api.UserProfile>>(
  (ref) => _pagedMembers(ref, ref.watch(apiProvider), null),
);

/// The members who can view [channelId], for a member pane sitting beside
/// that channel. Same endpoint and same paging as [membersProvider]; the
/// server applies the filter before it cuts a page, so the short-page
/// contract this loop relies on still holds.
///
/// A separate provider rather than a parameter on [membersProvider]: the
/// roster's other readers - role assignment, the overwrite pickers, the
/// removed-members screen - all want the deployment-wide list, and narrowing
/// it under them would hide exactly the people they exist to reach.
final channelMembersProvider = FutureProvider.autoDispose
    .family<List<api.UserProfile>, String>(
      (ref, channelId) => _pagedMembers(ref, ref.watch(apiProvider), channelId),
    );

Future<List<api.UserProfile>> _pagedMembers(
  Ref ref,
  api.SlimmApi client,
  String? channelId,
) async {
  var superseded = false;
  ref.onDispose(() => superseded = true);
  final members = <api.UserProfile>[];
  String? after;
  for (var page = 0; page < _maxMemberPages && !superseded; page++) {
    final batch = await client.listMembers(
      after: after,
      limit: _memberPageLimit,
      channel: channelId,
    );
    members.addAll(batch);
    if (batch.length < _memberPageLimit) return members;
    after = batch.last.id;
  }
  return members;
}

/// Seeds live presence for the member list the pane is actually showing. A
/// trigger, not a data source in its own right: `AppMemberPane` watches this
/// purely to start it, and reads the actual statuses back from
/// [presenceControllerProvider]. `autoDispose`, and depending on the (also
/// `autoDispose`) roster, keeps this from outliving the pane, unlike
/// [presenceControllerProvider] itself, which is worth keeping warm for the
/// rest of the session.
///
/// Keyed on the same channel the pane is, so it seeds from the same list
/// rather than fetching the deployment roster beside it: seeding from
/// [membersProvider] while the pane read [channelMembersProvider] meant two
/// full pagings of `/members` per mount for one pane.
final presenceSeedProvider = FutureProvider.autoDispose.family<void, String?>((
  ref,
  channelId,
) async {
  final members = channelId == null
      ? await ref.watch(membersProvider.future)
      : await ref.watch(channelMembersProvider(channelId).future);
  await ref
      .read(presenceControllerProvider.notifier)
      .refresh(members.map((m) => m.id));
});

/// Refetches the roster when an event says one of its rows is now wrong:
/// somebody joined (`api.MemberJoined`, on registration or an invite
/// redemption - never a restore, which is its own event below), was timed
/// out (their badge belongs on screen), had a timeout lifted, was removed
/// (they belong off it), was restored (they belong back on it), or had a
/// role granted or revoked (their role badges are wrong until refetched), or a
/// role was edited (its name, order or hoist flag places members in the pane).
///
/// One provider for all of these because every one of them is explicit and
/// exact. The events are exact but a bulk role change or a registration wave
/// sends many, and each refetch pages the whole roster, so a burst settles
/// for [memberRosterRefetchDelay] into one refetch.
final memberModerationWatcherProvider = Provider.autoDispose<void>((ref) {
  Timer? settle;
  ref.onDispose(() => settle?.cancel());
  final sub = ref.read(liveEventsProvider).listen((event) {
    if (event is api.MemberJoined ||
        event is api.MemberTimeoutChanged ||
        event is api.MemberRemoved ||
        event is api.MemberRestored ||
        event is api.MemberRoleChanged ||
        event is api.RoleChanged) {
      settle?.cancel();
      settle = Timer(memberRosterRefetchDelay, () {
        ref.invalidate(membersProvider);
        // A role change can also change who may view a channel at all.
        ref.invalidate(channelMembersProvider);
      });
    }
  });
  // A roster that failed during an outage has no event coming to refill it. Watches the latch rather than the controller, which a pane has no business starting.
  ref.listen<bool>(hasFailedSinceLiveProvider, (previous, failed) {
    if (previous != true || failed) return;
    ref.invalidate(membersProvider);
    ref.invalidate(channelMembersProvider);
  });
  ref.onDispose(() => unawaited(sub.cancel()));
});

/// Away and do-not-disturb both count as "online" for grouping purposes:
/// both are a live, connected session, just with a status layered on top,
/// and grouping either under "Offline" would read as a lie the row's own
/// presence dot then has to contradict.
bool isReachablePresence(AppPresence status) =>
    status == AppPresence.online ||
    status == AppPresence.away ||
    status == AppPresence.dnd;

/// Live per-member profile edits [membersProvider]'s roster snapshot does not
/// pick up on its own: that provider only refetches on an inferred join or a
/// moderation event, never on a plain `PATCH /me` (a display name or status
/// text edit), so a member pane row kept showing whatever it last paged in
/// until one of those unrelated events happened to also invalidate it -
/// including for the caller's own edit. `status_text_row.dart`'s own doc
/// comment
/// already assumed a rename or a status edit "goes through the one event
/// that already tells every other client to re-ask"
/// ([api.ProfileChanged]); nothing had actually wired that event to the
/// roster until this did.
///
/// Mirrors [PresenceController]'s live-overlay shape rather than patching
/// [membersProvider]'s list in place: that provider is a plain
/// `FutureProvider.autoDispose` with no settable state of its own, and a
/// blanket `ref.invalidate` on every status-text submit would re-page a
/// possibly large roster for a one-row change.
class MemberProfileOverridesController
    extends StateNotifier<Map<String, api.UserProfile>> {
  MemberProfileOverridesController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event is api.ProfileChanged) unawaited(_refetch(event.userId));
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// Applies a profile the caller already knows is current - the response of
  /// its own successful `PATCH /me` - without waiting on that same edit's
  /// [api.ProfileChanged] echo to round-trip back down this connection.
  void applyKnown(api.UserProfile profile) {
    state = {...state, profile.id: profile};
  }

  /// [api.ProfileChanged] carries only an id (see its own doc comment), so
  /// this is what "re-ask" means in practice: fetch that one profile and
  /// merge it in, rather than a refetch of the whole roster.
  Future<void> _refetch(String userId) async {
    try {
      final profile = await _ref.read(apiProvider).getUser(userId);
      if (!mounted) return;
      state = {...state, userId: profile};
    } on api.ApiException {
      // Left stale; the next ProfileChanged (or a roster refetch) corrects it.
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Kept alive for the session, matching [presenceControllerProvider]: cheap
/// to hold, and reused across the member pane closing and reopening rather
/// than refetched every time it does.
final memberProfileOverridesProvider =
    StateNotifierProvider<
      MemberProfileOverridesController,
      Map<String, api.UserProfile>
    >((ref) => MemberProfileOverridesController(ref));

/// A stable, order-independent summary of who currently reads as reachable
/// (online/away/dnd), meant for `presenceControllerProvider.select`. `Map`
/// has no structural `==`, so selecting the raw map can never detect "no
/// group-relevant change" and would rebuild a watcher on every single
/// presence event; joining the reachable ids into a sorted `String` gives
/// `.select` something two calls can actually compare, so a watcher of this
/// only rebuilds when someone crosses between the Online and Offline
/// sections, not on every dot-colour change within the same one.
String reachablePresenceKey(Map<String, api.PresenceState> presence) {
  final ids = [
    for (final entry in presence.entries)
      if (entry.value != api.PresenceState.offline) entry.key,
  ]..sort();
  return ids.join(',');
}
