// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Deployment-wide settings. The writes require MANAGE_SERVER.
extension SlimmApiSpace on SlimmApi {
  Future<SpaceSettings> spaceSettings() async {
    final json = await send('GET', '/space/settings');
    return SpaceSettings.fromJson(json as Map<String, dynamic>);
  }

  /// Writes whichever fields are given and leaves the rest alone.
  ///
  /// A field is omitted rather than echoed back when the caller does not mean
  /// to change it: the server writes only what is present, so a screen holding
  /// a stale snapshot cannot overwrite the operator's other choice. At least
  /// one is required. An empty [welcomeChannelId] clears the welcome channel.
  Future<SpaceSettings> setSpaceSettings(SpaceSettingsUpdate update) async {
    final SpaceSettingsUpdate(
      :name,
      :joinPolicy,
      :totpPolicy,
      :description,
      :strongNoiseSuppression,
      :membersCanInvite,
      :welcomeEnabled,
      :welcomeChannelId,
      :welcomeMessage,
    ) = update;
    assert(
      name != null ||
          joinPolicy != null ||
          totpPolicy != null ||
          description != null ||
          strongNoiseSuppression != null ||
          membersCanInvite != null ||
          welcomeEnabled != null ||
          welcomeChannelId != null ||
          welcomeMessage != null,
      'a settings PATCH must carry at least one field',
    );
    final json = await send(
      'PATCH',
      '/space/settings',
      body: {
        if (name != null) 'name': name,
        if (joinPolicy != null) 'join_policy': joinPolicy.wire,
        if (totpPolicy != null) 'totp_policy': totpPolicy.wire,
        if (description != null) 'description': description,
        if (strongNoiseSuppression != null)
          'strong_noise_suppression': strongNoiseSuppression,
        if (membersCanInvite != null) 'members_can_invite': membersCanInvite,
        if (welcomeEnabled != null) 'welcome_enabled': welcomeEnabled,
        if (welcomeChannelId != null) 'welcome_channel_id': welcomeChannelId,
        if (welcomeMessage != null) 'welcome_message': welcomeMessage,
      },
    );
    return SpaceSettings.fromJson(json as Map<String, dynamic>);
  }

  /// Sets the invite landing card's banner and returns when it was stored.
  Future<int> uploadSpaceBanner(List<int> bytes) async {
    final json = await send('POST', '/space/banner', bytes: bytes);
    return (json as Map<String, dynamic>)['banner_updated_at'] as int;
  }

  Future<void> deleteSpaceBanner() =>
      send('DELETE', '/space/banner', expectNoContent: true);

  Future<FetchedBytes> fetchSpaceBanner() => fetchBytes('/space/banner');

  /// Sets the space icon and returns when it was stored.
  Future<int> uploadSpaceIcon(List<int> bytes) async {
    final json = await send('POST', '/space/icon', bytes: bytes);
    return (json as Map<String, dynamic>)['icon_updated_at'] as int;
  }

  Future<void> deleteSpaceIcon() =>
      send('DELETE', '/space/icon', expectNoContent: true);

  Future<FetchedBytes> fetchSpaceIcon() => fetchBytes('/space/icon');

  Future<SpaceAnalytics> spaceAnalytics() async {
    final json = await send('GET', '/space/analytics');
    return SpaceAnalytics.fromJson(json as Map<String, dynamic>);
  }

  Future<SpaceAnalytics> setSpaceAnalyticsEnabled(bool enabled) async {
    final json = await send(
      'PATCH',
      '/space/analytics',
      body: {'enabled': enabled},
    );
    return SpaceAnalytics.fromJson(json as Map<String, dynamic>);
  }

  Future<int> spaceMessageRetentionDays() async {
    final json = await send('GET', '/space/retention');
    return (json as Map<String, dynamic>)['retention_days'] as int;
  }

  Future<int> setSpaceMessageRetentionDays(int days) async {
    final json = await send(
      'PATCH',
      '/space/retention',
      body: {'retention_days': days},
    );
    return (json as Map<String, dynamic>)['retention_days'] as int;
  }

  /// How many live messages a retention window of [days] would prune now.
  Future<int> previewSpaceMessageRetention(int days) async {
    final json = await send(
      'GET',
      '/space/retention/preview',
      query: {'days': '$days'},
    );
    return (json as Map<String, dynamic>)['messages'] as int;
  }

  Future<int> spaceCanvasObjectCap() async {
    final json = await send('GET', '/space/canvas-cap');
    return (json as Map<String, dynamic>)['object_cap'] as int;
  }

  Future<int> setSpaceCanvasObjectCap(int cap) async {
    final json = await send(
      'PATCH',
      '/space/canvas-cap',
      body: {'object_cap': cap},
    );
    return (json as Map<String, dynamic>)['object_cap'] as int;
  }

  Future<int> spaceScreenShareMaxHeight() async {
    final json = await send('GET', '/space/screen-share');
    return (json as Map<String, dynamic>)['max_height'] as int;
  }

  Future<int> setSpaceScreenShareMaxHeight(int maxHeight) async {
    final json = await send(
      'PATCH',
      '/space/screen-share',
      body: {'max_height': maxHeight},
    );
    return (json as Map<String, dynamic>)['max_height'] as int;
  }

  Future<bool> spaceLinkPreviews() async {
    final json = await send('GET', '/space/link-previews');
    return (json as Map<String, dynamic>)['enabled'] as bool;
  }

  Future<bool> setSpaceLinkPreviews(bool enabled) async {
    final json = await send(
      'PATCH',
      '/space/link-previews',
      body: {'enabled': enabled},
    );
    return (json as Map<String, dynamic>)['enabled'] as bool;
  }

  Future<SpaceAttachmentLimit> spaceAttachmentLimit() async {
    final json = await send('GET', '/space/attachment-limit');
    return SpaceAttachmentLimit.fromJson(json as Map<String, dynamic>);
  }

  /// [maxBytes] of 0 clears the admin limit.
  Future<SpaceAttachmentLimit> setSpaceAttachmentLimit(int maxBytes) async {
    final json = await send(
      'PATCH',
      '/space/attachment-limit',
      body: {'max_bytes': maxBytes},
    );
    return SpaceAttachmentLimit.fromJson(json as Map<String, dynamic>);
  }

  Future<SpaceMediaCompression> spaceMediaCompression() async {
    final json = await send('GET', '/space/media-compression');
    return SpaceMediaCompression.fromJson(json as Map<String, dynamic>);
  }

  /// Only the fields given change; an empty [extensions] restores the defaults.
  Future<SpaceMediaCompression> setSpaceMediaCompression({
    bool? enabled,
    List<String>? extensions,
    String? metadata,
    bool? keepOriginal,
  }) async {
    final json = await send(
      'PATCH',
      '/space/media-compression',
      body: {
        if (enabled != null) 'enabled': enabled,
        if (extensions != null) 'extensions': extensions,
        if (metadata != null) 'metadata': metadata,
        if (keepOriginal != null) 'keep_original': keepOriginal,
      },
    );
    return SpaceMediaCompression.fromJson(json as Map<String, dynamic>);
  }

  /// Operator-visible storage usage and sweep health. Always computes -
  /// there is no on/off toggle the way `spaceAnalytics` has.
  Future<SpaceStorage> fetchSpaceStorage() async {
    final json = await send('GET', '/space/storage');
    return SpaceStorage.fromJson(json as Map<String, dynamic>);
  }
}
