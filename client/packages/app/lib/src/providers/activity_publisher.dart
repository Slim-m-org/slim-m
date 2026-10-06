// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the server what this device is doing, and only when the person has
/// switched that on (decision 0044).
///
/// A feed is opened only while its switch is on, the caller has not chosen to
/// appear offline and the platform has the source. Otherwise it is never
/// started, so an opted-out or hidden device does not read a player, scan a
/// process list or call a third party. The server applies the same hidden
/// rule to every viewer; the check here is a second lock, not the only one.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'activity_feeds.dart';
import 'live_events.dart';
import 'presence_controller.dart';
import 'providers.dart';

class ActivityPublisher {
  ActivityPublisher(this._ref) {
    _ref.onDispose(_stop);
    final feeds = _ref.read(activityFeedsProvider);
    for (final feed in feeds) {
      _ref.listen<bool>(feed.enabled, (_, _) => _refresh());
      _ref.listen<bool>(feed.available, (_, _) => _refresh());
    }
    _ref.listen<api.PresenceVisibility?>(
      ownVisibilityProvider,
      (_, _) => _refresh(),
    );
    _events = _ref.read(liveEventsProvider).listen(_onEvent);
    _refresh();
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _events;
  final _open = <ActivityFeed, StreamSubscription<api.PresenceActivity?>>{};
  final _readings = <ActivityFeed, api.PresenceActivity>{};

  /// What the server refused from each feed. A refusal is about the value, so
  /// it will never be accepted on a retry: the feed is passed over until it
  /// reads something different, and the next feed is shared instead.
  final _rejected = <ActivityFeed, api.PresenceActivity>{};
  api.PresenceActivity? _sent;

  bool get _hidden =>
      _ref.read(ownVisibilityProvider) == api.PresenceVisibility.hidden;

  bool _wanted(ActivityFeed feed) =>
      _ref.read(feed.enabled) && _ref.read(feed.available) && !_hidden;

  void _refresh() {
    for (final feed in _ref.read(activityFeedsProvider)) {
      final running = _open.containsKey(feed);
      if (_wanted(feed) && !running) {
        _open[feed] = feed
            .open(_ref)
            .listen((activity) => _onReading(feed, activity));
      } else if (!_wanted(feed) && running) {
        unawaited(_open.remove(feed)!.cancel());
        _readings.remove(feed);
        _rejected.remove(feed);
      }
    }
    unawaited(_push());
  }

  void _onReading(ActivityFeed feed, api.PresenceActivity? activity) {
    if (activity == null) {
      _readings.remove(feed);
    } else {
      _readings[feed] = activity;
    }
    if (_rejected[feed] != activity) _rejected.remove(feed);
    unawaited(_push());
  }

  /// A reconnect drops the server's copy; our own presence frame arriving
  /// without an activity while we hold one is how that shows up.
  void _onEvent(api.ServerEvent event) {
    if (event is! api.PresenceChanged || event.activity != null) return;
    if (event.userId != _ref.read(sessionProvider).tokens?.userId) return;
    if (_sent == null) return;
    _sent = null;
    unawaited(_push());
  }

  (ActivityFeed, api.PresenceActivity)? _choose() {
    if (_hidden) return null;
    for (final feed in _ref.read(activityFeedsProvider)) {
      final reading = _readings[feed];
      if (reading == null || !_wanted(feed)) continue;
      if (_rejected[feed] == reading) continue;
      return (feed, reading);
    }
    return null;
  }

  Future<void> _push() async {
    final choice = _choose();
    final wanted = choice?.$2;
    if (wanted == _sent) return;
    final client = _ref.read(apiProvider);
    final previous = _sent;
    _sent = wanted;
    try {
      if (wanted == null) {
        await client.clearPresenceActivity();
      } else {
        await client.setPresenceActivity(wanted);
      }
      _ref.read(sharedActivityProvider.notifier).state = wanted;
      _ref.read(sharedFeedProvider.notifier).state = choice?.$1;
    } on api.BadRequestException {
      _sent = previous;
      if (choice != null) {
        _rejected[choice.$1] = choice.$2;
        unawaited(_push());
      }
    } on api.ApiException {
      // Retried by the next change; the server forgets it with the socket anyway.
      _sent = previous;
    }
  }

  void _stop() {
    unawaited(_events.cancel());
    for (final sub in _open.values) {
      unawaited(sub.cancel());
    }
    _open.clear();
  }
}

/// Watched from the signed-in shell so it lives for the session, the same
/// forced-instantiation shape the sound controller uses.
final activityPublisherProvider = Provider<ActivityPublisher>(
  (ref) => ActivityPublisher(ref),
);
