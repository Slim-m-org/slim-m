// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Channel renaming, deletion and reordering, plus channel-category CRUD:
/// the rest of the `channels` tag that [SlimmApi.listChannels] and
/// [SlimmApi.createChannel] do not cover. See
/// docs/decisions/0006-channel-categories.md for the category half.
extension SlimmApiChannelAdmin on SlimmApi {
  /// Renames a channel, replaces its topic, and/or sets its slow-mode
  /// interval. Requires MANAGE_CHANNELS at the deployment level, the same
  /// check creating a channel uses. At least one of [name], [topic],
  /// [slowModeSeconds] and [joinMuted] must be given; a blank or whitespace-only [topic]
  /// clears it back to none rather than storing an empty string.
  /// [slowModeSeconds] of 0 turns slow mode off; the server refuses, rather
  /// than clamps, a value outside 0 to 21600 (six hours). [joinMuted] sets
  /// whether joining a voice channel starts with the mic off.
  Future<Channel> updateChannel({
    required String channelId,
    String? name,
    String? topic,
    int? slowModeSeconds,
    bool? joinMuted,
  }) async {
    final json = await _send(
      'PATCH',
      '/channels/$channelId',
      body: {
        if (name != null) 'name': name,
        if (topic != null) 'topic': topic,
        if (slowModeSeconds != null) 'slow_mode_seconds': slowModeSeconds,
        if (joinMuted != null) 'join_muted': joinMuted,
      },
    );
    return Channel.fromJson(json as Map<String, dynamic>);
  }

  /// Soft-deletes a channel. Requires MANAGE_CHANNELS. Refused if this is the
  /// deployment's last live channel, since a deployment with zero channels
  /// has nowhere for anyone to land. Deleting an already-deleted channel is
  /// not an error.
  Future<void> deleteChannel(String channelId) =>
      _send('DELETE', '/channels/$channelId', expectNoContent: true);

  /// The caller's effective permission bitmask in this one channel: the
  /// per-channel sibling of `Me.permissions`. Already resolved through
  /// thread and DM handling with any timeout subtracted, and masked to zero
  /// whenever the caller lacks VIEW_CHANNEL here - including for a channel
  /// that does not exist at all, so this can never be used to probe for a
  /// channel's existence. See docs/decisions/0011-per-channel-permissions.md.
  Future<int> getChannelPermissions(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/permissions');
    return (json as Map<String, dynamic>)['permissions'] as int;
  }

  /// Sets the deployment's channel order and category placement. Requires
  /// MANAGE_CHANNELS. [groups] must, flattened, name exactly the live,
  /// non-DM, non-thread channel ids - no more, no fewer, no repeats - and
  /// every non-null `categoryId` it names must be a live category; a wrong
  /// or partial submission is refused with a 400 naming what was wrong
  /// rather than silently leaving a gap. Deployment-wide, not a per-device
  /// preference: everyone sees the same order. Returns every live, non-DM
  /// channel in its new arrangement.
  Future<List<Channel>> reorderChannels(List<ChannelOrderGroup> groups) async {
    final json = await _send(
      'PUT',
      '/channels/order',
      body: {
        'categories': groups.map((g) => g.toJson()).toList(growable: false),
      },
    );
    return (json as List<dynamic>)
        .map((c) => Channel.fromJson(c as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Every live category. Unfiltered by any permission: a category carries
  /// none of its own, so any authenticated caller may read the list. Its own
  /// route, not folded into [SlimmApi.listChannels]'s response: that would
  /// reshape an existing response, which the wire's additive-only rule does
  /// not allow.
  Future<List<ChannelCategory>> listCategories() async {
    final json = await _send('GET', '/categories');
    return (json as List<dynamic>)
        .map((c) => ChannelCategory.fromJson(c as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Creates a category, appended after every live one. Requires
  /// MANAGE_CHANNELS. [id] is an optional client-generated UUIDv7 that makes
  /// the create idempotent on retry.
  Future<ChannelCategory> createCategory(String name, {String? id}) async {
    final json = await _send(
      'POST',
      '/categories',
      body: {if (id != null) 'id': id, 'name': name},
    );
    return ChannelCategory.fromJson(json as Map<String, dynamic>);
  }

  /// Renames and/or repositions a category. At least one of [name] and
  /// [position] must be given. Requires MANAGE_CHANNELS.
  Future<ChannelCategory> updateCategory({
    required String categoryId,
    String? name,
    int? position,
  }) async {
    final json = await _send(
      'PATCH',
      '/categories/$categoryId',
      body: {
        if (name != null) 'name': name,
        if (position != null) 'position': position,
      },
    );
    return ChannelCategory.fromJson(json as Map<String, dynamic>);
  }

  /// Soft-deletes a category. Requires MANAGE_CHANNELS. Its channels are
  /// never deleted with it - they fall back to uncategorised. Deleting an
  /// already-deleted category is not an error.
  Future<void> deleteCategory(String categoryId) =>
      _send('DELETE', '/categories/$categoryId', expectNoContent: true);
}
