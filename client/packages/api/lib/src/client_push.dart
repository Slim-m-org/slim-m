// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Push registration, lifecycle reporting, and the caller's own account-wide
/// notification preference: the `push` tag.
///
/// Split out of `client.dart` purely to stay under this repo's line budget;
/// it used to sit directly on [SlimmApi] as a "--- Push ---" section.
extension SlimmApiPush on SlimmApi {
  /// Registers, or replaces, this device's push registration. The server seals
  /// a content-free envelope to [pushPublicKey]; only this device holds the
  /// matching private key, so a device that never registers one gets no push.
  ///
  /// [includeContent] is the member's explicit choice about a sealed preview,
  /// saved to the account. Null (the default) leaves the account's own choice
  /// alone, so a device that never toggled cannot reset one made elsewhere.
  Future<void> registerPush({
    required String platform,
    required String pushToken,
    String? voipPushToken,
    required String pushPublicKey,
    bool? includeContent,
  }) =>
      _send(
        'PUT',
        '/push',
        body: {
          'platform': platform,
          'push_token': pushToken,
          'voip_push_token': voipPushToken,
          'push_public_key': pushPublicKey,
          if (includeContent != null) ...{
            'include_content': includeContent,
            'include_content_chosen': true,
          },
        },
        expectNoContent: true,
      );

  /// Whether push envelopes carry a message preview: the account's choice,
  /// else the server default.
  Future<bool> pushPreview() async {
    final json = await _send('GET', '/push/preview');
    return (json as Map<String, dynamic>)['include_content'] as bool;
  }

  /// Saves the member's explicit preview choice to the account.
  Future<void> setPushPreview(bool includeContent) =>
      _send('PUT', '/push/preview', body: {'include_content': includeContent});

  /// Clears this device's push registration.
  Future<void> unregisterPush() =>
      _send('DELETE', '/push', expectNoContent: true);

  /// Reports this device's app lifecycle state. Push is triggered from this
  /// self-reported state rather than WebSocket presence, because a suspended
  /// but still-connected socket is not proof the app can show a notification.
  Future<void> reportPushLifecycle({required String state}) => _send(
        'PUT',
        '/push/lifecycle',
        body: {'state': state},
        expectNoContent: true,
      );

  /// Reads the caller's own notification preference. Account-wide, unlike
  /// every other call in this extension: which messages are worth waking any
  /// of this account's devices for, not one device's own registration.
  ///
  /// A [NotFoundException] means this server predates the route, which a
  /// caller must read as "not offered here", never as
  /// [NotificationPreference.everything].
  Future<NotificationPreference> notificationPreference() async {
    final json = await _send('GET', '/push/preference');
    return NotificationPreference.parse(
      (json as Map<String, dynamic>)['preference'] as String,
    );
  }

  /// Sets the caller's own notification preference. Enforced where push
  /// recipients are computed, before a device is ever woken - never a filter
  /// this client applies to a push that has already landed.
  Future<NotificationPreference> setNotificationPreference(
    NotificationPreference preference,
  ) async {
    final json = await _send(
      'PUT',
      '/push/preference',
      body: {'preference': preference.wire},
    );
    return NotificationPreference.parse(
      (json as Map<String, dynamic>)['preference'] as String,
    );
  }

  /// The caller's own per-channel overrides - only channels actually
  /// overridden, never one listed at [NotificationPreference.everything]:
  /// having no entry there already means that.
  Future<List<ChannelNotificationOverride>>
      listChannelNotificationOverrides() async {
    final json = await _send('GET', '/notification-preferences/channels');
    return (json as List<dynamic>)
        .map(
          (e) => ChannelNotificationOverride.fromJson(
            e as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  /// Mutes [channelId], or narrows it to mentions only. [preference] must be
  /// [NotificationPreference.mentions] or [NotificationPreference.nothing];
  /// the server refuses [NotificationPreference.everything], since having no
  /// override already means that - clear it with
  /// [clearChannelNotificationOverride] instead.
  Future<ChannelNotificationOverride> setChannelNotificationOverride(
    String channelId,
    NotificationPreference preference,
  ) async {
    final json = await _send(
      'PUT',
      '/notification-preferences/channels/$channelId',
      body: {'preference': preference.wire},
    );
    return ChannelNotificationOverride.fromJson(json as Map<String, dynamic>);
  }

  /// Clears [channelId]'s override, reverting it to the account default.
  Future<void> clearChannelNotificationOverride(String channelId) => _send(
        'DELETE',
        '/notification-preferences/channels/$channelId',
        expectNoContent: true,
      );
}
