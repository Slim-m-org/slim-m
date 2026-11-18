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
import 'package:slimm_data/data.dart' show CategoryStore, Channel;

import '../../../providers/providers.dart';

/// What [channel] gives members with no choice of their own, or null when it
/// sets no default (`everything` is the same as none); a voice chat's is mentions.
api.NotificationPreference? channelDefaultOf(Channel channel) {
  final level = api.NotificationPreference.parse(
    channel.defaultNotification ?? 'everything',
  );
  if (level != api.NotificationPreference.everything) return level;
  return channel.kind == 'voice' ? api.NotificationPreference.mentions : null;
}

class ChannelNotificationOverridesState {
  const ChannelNotificationOverridesState({
    this.byChannel = const {},
    this.settled = false,
    this.error,
    this.categoriesFailed = false,
    this.mutedCategories = const {},
    this.categoryParents = const {},
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

  /// Whether the last read of the muted categories failed, so the next connect asks again.
  final bool categoriesFailed;

  /// The categories this account muted itself; a sub-category of one is muted with it.
  final Set<String> mutedCategories;

  /// Each sub-category's parent, read only while a category is muted.
  final Map<String, String> categoryParents;

  ChannelNotificationOverridesState copyWith({
    Map<String, api.NotificationPreference>? byChannel,
    bool? settled,
    String? error,
    bool clearError = false,
    bool? categoriesFailed,
    Set<String>? mutedCategories,
    Map<String, String>? categoryParents,
  }) => ChannelNotificationOverridesState(
    byChannel: byChannel ?? this.byChannel,
    settled: settled ?? this.settled,
    error: clearError ? null : error ?? this.error,
    categoriesFailed: categoriesFailed ?? this.categoriesFailed,
    mutedCategories: mutedCategories ?? this.mutedCategories,
    categoryParents: categoryParents ?? this.categoryParents,
  );

  /// Whether [categoryId] is quiet: muted itself, or filed under a muted category.
  bool isCategoryMuted(String? categoryId) =>
      categoryId != null &&
      (mutedCategories.contains(categoryId) ||
          mutedCategories.contains(categoryParents[categoryId]));

  /// What [channel] follows when this account set nothing for it: muted by its category, else its own default.
  api.NotificationPreference? defaultFor(Channel channel) =>
      isCategoryMuted(channel.categoryId)
      ? api.NotificationPreference.nothing
      : channelDefaultOf(channel);

  /// [channelId]'s own override, or `null` when it is following the account
  /// default.
  api.NotificationPreference? overrideFor(String channelId) =>
      byChannel[channelId];

  /// What [channel] shows and sounds as: this account's own choice for it, else
  /// [defaultFor]. The account-wide preference stays out, for the
  /// reason `unreadIndicatorFor` gives.
  api.NotificationPreference? effectiveFor(Channel channel) =>
      byChannel[channel.id] ?? defaultFor(channel);

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
    state = state.copyWith(byChannel: byChannel);
  }

  /// Another device of this account muted or unmuted [categoryId].
  void applyRemoteCategory(String categoryId, {required bool muted}) {
    _categoryEdits[categoryId] = muted;
    _showCategory(categoryId, muted: muted);
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

  /// [_edits] for category mutes.
  final Map<String, bool> _categoryEdits = {};

  /// Follows the category tree once something is muted, so a sub-category resolves to its parent.
  ProviderSubscription<AsyncValue<Map<String, String>>>? _parents;

  void _onSessionChanged(api.TokenPair? tokens) {
    if (tokens != null && tokens.userId == _account) return;
    _account = tokens?.userId;
    _generation++;
    _edits.clear();
    _categoryEdits.clear();
    _parents?.close();
    _parents = null;
    state = const ChannelNotificationOverridesState();
    if (tokens != null) unawaited(refresh());
  }

  /// Reads the list back from the server, replacing what is held. Catches
  /// everything, not just [api.ApiException]: this runs unawaited from the
  /// constructor and from a session change, so anything that escapes it
  /// reaches no caller at all.
  Future<void> refresh() async {
    final generation = ++_generation;
    _edits.clear();
    _categoryEdits.clear();
    await Future.wait([
      _refreshChannels(generation),
      _refreshCategories(generation),
    ]);
  }

  Future<void> _refreshChannels(int generation) async {
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
      state = state.copyWith(
        byChannel: byChannel,
        settled: true,
        clearError: true,
      );
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'refresh channel notification settings',
        error,
        stack,
      );
      if (!mounted || generation != _generation) return;
      final message = error is api.ApiException ? error.message : '$error';
      state = state.copyWith(settled: true, error: message);
    }
  }

  /// Reads the muted categories apart from the overrides: a server without the route leaves only these unknown.
  Future<void> _refreshCategories(int generation) async {
    try {
      final muted = (await _ref.read(apiProvider).listCategoryMutes()).toSet();
      if (!mounted || generation != _generation) return;
      for (final MapEntry(:key, :value) in _categoryEdits.entries) {
        value ? muted.add(key) : muted.remove(key);
      }
      state = state.copyWith(mutedCategories: muted, categoriesFailed: false);
      _followParents();
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.ui,
        'refresh muted categories',
        error,
        stack,
      );
      if (!mounted || generation != _generation) return;
      state = state.copyWith(categoriesFailed: true);
    }
  }

  /// Mutes every channel under [categoryId] that has no choice of its own.
  Future<void> muteCategory(String categoryId) => _changeCategory(
    categoryId,
    muted: true,
    request: () => _ref.read(apiProvider).muteCategory(categoryId),
  );

  /// Unmutes [categoryId].
  Future<void> unmuteCategory(String categoryId) => _changeCategory(
    categoryId,
    muted: false,
    request: () => _ref.read(apiProvider).unmuteCategory(categoryId),
  );

  Future<void> _changeCategory(
    String categoryId, {
    required bool muted,
    required Future<void> Function() request,
  }) async {
    _categoryEdits[categoryId] = muted;
    _showCategory(categoryId, muted: muted);
    try {
      await request();
    } catch (_) {
      if (mounted &&
          state.mutedCategories.contains(categoryId) == muted &&
          _categoryEdits[categoryId] == muted) {
        _categoryEdits.remove(categoryId);
        _showCategory(categoryId, muted: !muted);
      }
      rethrow;
    }
  }

  void _showCategory(String categoryId, {required bool muted}) {
    final next = {...state.mutedCategories};
    muted ? next.add(categoryId) : next.remove(categoryId);
    state = state.copyWith(mutedCategories: next);
    _followParents();
  }

  void _followParents() {
    if (_parents != null || state.mutedCategories.isEmpty) return;
    _parents = _ref.listen(categoryParentsProvider, (_, next) {
      final parents = next.valueOrNull;
      if (parents != null && mounted) {
        state = state.copyWith(categoryParents: parents);
      }
    }, fireImmediately: true);
  }

  /// Mutes [channelId] entirely.
  Future<void> mute(String channelId) => _change(
    channelId,
    api.NotificationPreference.nothing,
    () => _ref
        .read(apiProvider)
        .setChannelNotificationOverride(
          channelId,
          api.NotificationPreference.nothing,
        ),
  );

  /// Asks for every message in [channelId], past a mentions-only default.
  Future<void> everything(String channelId) => _change(
    channelId,
    api.NotificationPreference.everything,
    () => _ref
        .read(apiProvider)
        .setChannelNotificationOverride(
          channelId,
          api.NotificationPreference.everything,
        ),
  );

  /// Narrows [channelId] to mentions only.
  Future<void> mentionsOnly(String channelId) => _change(
    channelId,
    api.NotificationPreference.mentions,
    () => _ref
        .read(apiProvider)
        .setChannelNotificationOverride(
          channelId,
          api.NotificationPreference.mentions,
        ),
  );

  /// Clears [channelId]'s override, reverting it to the account default.
  Future<void> clear(String channelId) => _change(
    channelId,
    null,
    () => _ref.read(apiProvider).clearChannelNotificationOverride(channelId),
  );

  /// Shows [preference] for [channelId] at once (null is no override) and, if
  /// [request] fails, puts back that channel alone, and only if nothing newer
  /// has changed it since, so a slow failure cannot undo another edit.
  Future<void> _change(
    String channelId,
    api.NotificationPreference? preference,
    Future<void> Function() request,
  ) async {
    final previous = state.byChannel[channelId];
    _edits[channelId] = preference;
    _show(channelId, preference);
    try {
      await request();
    } catch (_) {
      if (mounted && state.byChannel[channelId] == preference) {
        _edits.remove(channelId);
        _show(channelId, previous);
      }
      rethrow;
    }
  }

  void _show(String channelId, api.NotificationPreference? preference) {
    final byChannel = {...state.byChannel};
    if (preference == null) {
      byChannel.remove(channelId);
    } else {
      byChannel[channelId] = preference;
    }
    state = state.copyWith(byChannel: byChannel);
  }

  @override
  void dispose() {
    _parents?.close();
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Each sub-category's parent, from the local category table.
final categoryParentsProvider = StreamProvider<Map<String, String>>((
  ref,
) async* {
  final store = await ref.watch(storeProvider.future);
  yield* store.watchCategories().map(
    (rows) => {
      for (final row in rows)
        if (row.parentId case final parent?) row.id: parent,
    },
  );
});

/// Deliberately not `autoDispose`: every surface that shows a channel as
/// muted reads it, so its lifetime is the session's, the same choice
/// [blocksProvider] makes and for the same reason.
final channelNotificationOverridesProvider =
    StateNotifierProvider<
      ChannelNotificationOverridesController,
      ChannelNotificationOverridesState
    >((ref) => ChannelNotificationOverridesController(ref));
