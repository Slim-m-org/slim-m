// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channels this account has muted, or narrowed to mentions only,
/// held for as long as the session lasts - the client-side counterpart of
/// `store/channel_notification_prefs.rs`.
///
/// [blocks_controller.dart]'s own doc comment already draws the shape this
/// follows: every read surface that has to show a channel as muted (the
/// rail's glyph, the header's overflow, `notification_sound_rules.dart`'s
/// chime gate) consults this, and a set that lives only while one settings
/// pane is mounted means nothing is shown anywhere else.
///
/// This is a view of the server's own answer, not a second source of truth:
/// every mutation round-trips through `SlimmApi`, and a channel absent from
/// [ChannelNotificationOverridesState.byChannel] is following the account
/// default (`notification_preference_controller.dart`'s own account-wide
/// layer), never assumed muted or unmuted client-side.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'providers.dart';

class ChannelNotificationOverridesState {
  const ChannelNotificationOverridesState({
    this.byChannel = const {},
    this.settled = false,
    this.error,
  });

  /// Every channel this account has overridden, and what to. A channel
  /// absent here is following the account default.
  final Map<String, api.NotificationPreference> byChannel;

  /// Whether the server has been asked and has answered, either way - the
  /// same "not asked yet" versus "asked and empty" distinction
  /// `BlocksState.settled` draws.
  final bool settled;

  /// Why the last fetch or change failed, for a settings screen that lists
  /// these.
  final String? error;

  /// [channelId]'s own override, or `null` when it is following the account
  /// default - never [api.NotificationPreference.everything] itself, since
  /// an override is never actually stored at that value.
  api.NotificationPreference? overrideFor(String channelId) =>
      byChannel[channelId];

  /// Whether [channelId] is muted entirely, the one state the rail's glyph
  /// renders for.
  bool isMuted(String channelId) =>
      byChannel[channelId] == api.NotificationPreference.nothing;
}

class ChannelNotificationOverridesController
    extends StateNotifier<ChannelNotificationOverridesState> {
  ChannelNotificationOverridesController(this._ref)
    : super(const ChannelNotificationOverridesState()) {
    _account = _ref.read(sessionProvider).tokens?.userId;
    _sub = _ref.read(sessionProvider).changes.listen(_onSessionChanged);
    unawaited(refresh());
  }

  final Ref _ref;
  late final StreamSubscription<api.TokenPair?> _sub;

  /// Another device of this account set ([preference]) or cleared (null) an
  /// override; the live socket hands it over through `SyncController`.
  void applyRemote(String channelId, api.NotificationPreference? preference) {
    final byChannel = {...state.byChannel};
    if (preference == null) {
      byChannel.remove(channelId);
    } else {
      byChannel[channelId] = preference;
    }
    _edits[channelId] = preference;
    state = ChannelNotificationOverridesState(
      byChannel: byChannel,
      settled: state.settled,
    );
  }

  /// Whose overrides are held, so a session change that is only a token
  /// rotation is told apart from a different account signing in - the same
  /// distinction [blocksProvider]'s own controller draws for the identical
  /// reason.
  String? _account;

  /// Bumped by every load and every session change, so an answer that is no
  /// longer the latest is dropped. A change does not bump it: dropping the
  /// whole answer for one edit left every other override unloaded.
  int _generation = 0;

  /// What was changed since the load in flight began, laid over its answer so
  /// the edit is not undone by a response that was sent before it.
  final Map<String, api.NotificationPreference?> _edits = {};

  void _onSessionChanged(api.TokenPair? tokens) {
    if (tokens == null) {
      _generation++;
      _edits.clear();
      _account = null;
      state = const ChannelNotificationOverridesState();
      return;
    }
    if (tokens.userId == _account) return;
    _account = tokens.userId;
    _generation++;
    _edits.clear();
    state = const ChannelNotificationOverridesState();
    unawaited(refresh());
  }

  /// Reads the list back from the server, replacing what is held. Catches
  /// everything, not just [api.ApiException]: this runs unawaited from the
  /// constructor and from a session change, so anything that escapes it
  /// reaches no caller at all.
  Future<void> refresh() async {
    final generation = ++_generation;
    _edits.clear();
    try {
      final overrides = await _ref
          .read(apiProvider)
          .listChannelNotificationOverrides();
      if (!mounted || generation != _generation) return;
      final byChannel = {for (final o in overrides) o.channelId: o.preference};
      for (final MapEntry(:key, :value) in _edits.entries) {
        if (value == null) {
          byChannel.remove(key);
        } else {
          byChannel[key] = value;
        }
      }
      state = ChannelNotificationOverridesState(
        byChannel: byChannel,
        settled: true,
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final message = error is api.ApiException ? error.message : '$error';
      state = ChannelNotificationOverridesState(
        byChannel: state.byChannel,
        settled: true,
        error: message,
      );
    }
  }

  /// Mutes [channelId] entirely.
  Future<void> mute(String channelId) =>
      _set(channelId, api.NotificationPreference.nothing);

  /// Narrows [channelId] to mentions only.
  Future<void> mentionsOnly(String channelId) =>
      _set(channelId, api.NotificationPreference.mentions);

  Future<void> _set(
    String channelId,
    api.NotificationPreference preference,
  ) async {
    final before = state.byChannel;
    final after = {...before, channelId: preference};
    _edits[channelId] = preference;
    state = ChannelNotificationOverridesState(
      byChannel: after,
      settled: state.settled,
    );
    try {
      await _ref
          .read(apiProvider)
          .setChannelNotificationOverride(channelId, preference);
    } catch (_) {
      _edits.remove(channelId);
      if (mounted) {
        state = ChannelNotificationOverridesState(
          byChannel: before,
          settled: state.settled,
        );
      }
      rethrow;
    }
  }

  /// Clears [channelId]'s override, reverting it to the account default.
  Future<void> clear(String channelId) async {
    final before = state.byChannel;
    final after = {...before}..remove(channelId);
    _edits[channelId] = null;
    state = ChannelNotificationOverridesState(
      byChannel: after,
      settled: state.settled,
    );
    try {
      await _ref.read(apiProvider).clearChannelNotificationOverride(channelId);
    } catch (_) {
      _edits.remove(channelId);
      if (mounted) {
        state = ChannelNotificationOverridesState(
          byChannel: before,
          settled: state.settled,
        );
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Deliberately not `autoDispose`: every surface that shows a channel as
/// muted reads it, so its lifetime is the session's, the same choice
/// [blocksProvider] makes and for the same reason.
final channelNotificationOverridesProvider =
    StateNotifierProvider<
      ChannelNotificationOverridesController,
      ChannelNotificationOverridesState
    >((ref) => ChannelNotificationOverridesController(ref));
