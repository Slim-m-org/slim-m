// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Live presence: a batch lookup seeded once per member list, kept current
/// by `presence.changed` events for the rest of the session.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';
import 'presence_activity.dart';
import 'presence_devices.dart';
import '../../../providers/providers.dart';

/// The most ids `GET /presence` accepts in one request.
const _presenceBatchLimit = 100;

/// Every user this session currently has a presence status for. A user
/// absent from this map is simply unknown yet, never "offline": that
/// distinction belongs to the caller, which is why this holds
/// [api.PresenceState] rather than a design-system [AppPresence] already
/// defaulted to offline.
class PresenceController extends StateNotifier<Map<String, api.PresenceState>> {
  PresenceController(this._ref) : super(const {}) {
    _sub = _ref.read(liveEventsProvider).listen((event) {
      if (event is api.PresenceChanged) {
        _liveEventAt[event.userId] = ++_eventClock;
        state = {...state, event.userId: event.status};
        _ref
            .read(presenceActivityProvider.notifier)
            .apply(event.userId, event.activity);
        _ref
            .read(presenceDevicesProvider.notifier)
            .apply(event.userId, event.devices);
      }
    });
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;

  /// A tick per live event and per lookup, the tick each member's last event
  /// landed at, and the tick of the newest lookup that asked about them, so a
  /// batch response applies only to members nothing newer has answered for.
  int _eventClock = 0;
  final Map<String, int> _liveEventAt = {};
  final Map<String, int> _askedAt = {};

  /// Members whose presence this connection has already asked for: live events
  /// keep them current, so a roster that merely rebuilt need not ask again.
  final Set<String> _seeded = {};

  /// Forgets every cached status, for a session ending.
  ///
  /// This provider is deliberately app-lifetime rather than `autoDispose`, so
  /// nothing else would ever empty it: a sign-out followed by a different
  /// account signing in on the same device would show that account the
  /// previous one's presence - plainly wrong, since a status is per-person
  /// and the two accounts see different people online. Every sibling cache
  /// with this shape either runs its own session listener or is cleared by
  /// `SyncController`; this one had neither.
  void clear() {
    _liveEventAt.clear();
    _askedAt.clear();
    _seeded.clear();
    if (mounted) state = const {};
  }

  /// Asks again about everyone this session has asked about, for a socket that
  /// just went live: changes before it was subscribed never arrive as events.
  Future<void> resync() => refresh(_askedAt.keys.toList(growable: false));

  /// [refresh] for whichever of [userIds] this connection has not asked about.
  Future<void> seed(Iterable<String> userIds) =>
      refresh(userIds.where((id) => !_seeded.contains(id)));

  /// Batch-fetches presence for [userIds] and merges it into what is already
  /// known, a request per [_presenceBatchLimit] ids because the server refuses
  /// a longer list outright and one refusal used to leave a large roster all
  /// unreported. Best-effort: a failed batch leaves its ids as they were
  /// rather than surfacing an error the member pane has nowhere to show.
  Future<void> refresh(Iterable<String> userIds) async {
    final ids = userIds.toList(growable: false);
    for (var start = 0; start < ids.length; start += _presenceBatchLimit) {
      final end = start + _presenceBatchLimit;
      await _refreshBatch(
        ids.sublist(start, end > ids.length ? ids.length : end),
      );
    }
  }

  Future<void> _refreshBatch(List<String> ids) async {
    final askedAt = ++_eventClock;
    for (final id in ids) {
      _askedAt[id] = askedAt;
    }
    try {
      final all = await _ref.read(apiProvider).listPresence(ids);
      if (!mounted) return;
      _seeded.addAll(ids);
      // A live event or a lookup newer than this one is fresher than its snapshot.
      final statuses = all
          .where(
            (status) =>
                (_liveEventAt[status.userId] ?? 0) < askedAt &&
                _askedAt[status.userId] == askedAt,
          )
          .toList(growable: false);
      state = {
        ...state,
        for (final status in statuses) status.userId: status.status,
      };
      _ref.read(presenceActivityProvider.notifier).applyBatch(statuses);
      _ref.read(presenceDevicesProvider.notifier).applyBatch(statuses);
    } on api.ApiException catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'refresh member presence', error, stack);
      // Nothing useful to do; the next refresh (or a live event) corrects it.
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Kept alive for the app's session rather than `autoDispose`: presence is
/// cheap to hold and reused across the member pane closing and reopening,
/// so there is no reason to lose it and refetch every time the pane toggles.
final presenceControllerProvider =
    StateNotifierProvider<PresenceController, Map<String, api.PresenceState>>(
      (ref) => PresenceController(ref),
    );

/// The visibility the caller chose in this session, or null before they
/// choose one. Written by the status menu and the tray; read through
/// [ownVisibilityProvider], which falls back to what the server stored.
final presenceVisibilityDisplayProvider =
    StateProvider<api.PresenceVisibility?>((ref) => null);

/// The caller's own visibility: a choice made this session, else the one the
/// server stored (`GET /me`), else null while that has not loaded or when the
/// server is too old to say.
///
/// The server answers the caller's own id as online even when they chose to
/// appear offline, so without the stored value a fresh launch told a hidden
/// member they were visible. It is not persisted on the device: a stale copy
/// would say hidden after another device had made them visible.
final ownVisibilityProvider = Provider<api.PresenceVisibility?>(
  (ref) => _ownVisibility(ref.watch),
);

final _storedVisibility = effectiveMeProvider.select(
  (me) => me?.presenceVisibility,
);

api.PresenceVisibility? _ownVisibility(
  T Function<T>(ProviderListenable<T> provider) read,
) {
  final chosen = read(presenceVisibilityDisplayProvider);
  if (chosen != null) return chosen;
  final stored = read(_storedVisibility);
  return stored == null ? null : api.PresenceVisibility.parse(stored);
}

/// [ownVisibilityProvider] read from its sources, for code that runs with no
/// frame drawn: the tray sets "appear offline" on a window that draws none.
api.PresenceVisibility? ownVisibilityNow(Ref ref) => _ownVisibility(ref.read);

/// Runs [onChange] at once when the caller's own visibility may have changed.
void onOwnVisibilityChanged(Ref ref, void Function() onChange) {
  ref.listen(presenceVisibilityDisplayProvider, (_, _) => onChange());
  ref.listen(_storedVisibility, (_, _) => onChange());
}
