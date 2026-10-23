// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

/// Handshake, keepalive and error frames.
ServerEvent? _coreFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'hello' => HelloEvent(protocol: decoded['protocol'] as int? ?? 0),
    'category.changed' => const CategoryChanged(),
    'reports.changed' => const ReportsChanged(),
    'pong' => const PongEvent(),
    'error' => ErrorEvent(decoded['message'] as String? ?? 'unknown'),
    _ => null,
  };
}

/// Message lifecycle, reaction, pin, thread and poll frames.
ServerEvent? _messageFrame(Map<String, dynamic> decoded) {
  final message = decoded['message'];
  return switch (decoded['type']) {
    'message.created' when message is Map<String, dynamic> => MessageCreated(
        Message.fromJson(message),
      ),
    'message.edited' when message is Map<String, dynamic> => MessageEdited(
        Message.fromJson(message),
        opSeq: decoded['op_seq'] as int?,
      ),
    'message.deleted'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String =>
      MessageDeleted(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        opSeq: decoded['op_seq'] as int?,
      ),
    'reactions.changed'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String &&
            decoded['reactions'] is List =>
      ReactionsChanged(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        reactions: (decoded['reactions'] as List<dynamic>)
            .map((r) => ReactionTally.fromJson(r as Map<String, dynamic>))
            .toList(growable: false),
      ),
    // The frame's fields are a CodeRun plus the channel/message it belongs to.
    'code_run.changed'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String &&
            decoded['block_index'] is int =>
      CodeRunChanged(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        run: CodeRun.fromJson(decoded),
      ),
    'code_runs.cleared'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String =>
      CodeRunsCleared(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
      ),
    'thread.updated'
        when decoded['channel_id'] is String &&
            decoded['parent_message_id'] is String &&
            decoded['thread_channel_id'] is String &&
            decoded['reply_count'] is int =>
      ThreadUpdated(
        channelId: decoded['channel_id'] as String,
        parentMessageId: decoded['parent_message_id'] as String,
        threadChannelId: decoded['thread_channel_id'] as String,
        replyCount: decoded['reply_count'] as int,
        lastReplyAt: decoded['last_reply_at'] as int?,
      ),
    'message.pinned'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String &&
            decoded['pinned_at'] is int =>
      MessagePinned(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        pinnedBy: decoded['pinned_by'] as String?,
        pinnedAt: decoded['pinned_at'] as int,
      ),
    'message.unpinned'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String =>
      MessageUnpinned(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
      ),
    'poll.voted'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String &&
            decoded['options'] is List =>
      PollVoted(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        options: (decoded['options'] as List<dynamic>)
            .map((o) => PollOptionTally.fromJson(o as Map<String, dynamic>))
            .toList(growable: false),
        runoff: decoded['runoff'] is Map<String, dynamic>
            ? PollRunoff.fromJson(decoded['runoff'] as Map<String, dynamic>)
            : null,
      ),
    _ => null,
  };
}

/// Typing, read state, interactive component and ephemeral frames.
ServerEvent? _overlayFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'typing.started'
        when decoded['channel_id'] is String && decoded['user_id'] is String =>
      TypingStarted(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
      ),
    'typing.stopped'
        when decoded['channel_id'] is String && decoded['user_id'] is String =>
      TypingStopped(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
      ),
    'read_state.changed'
        when decoded['channel_id'] is String &&
            decoded['last_read_seq'] is int =>
      ReadStateChanged(
        channelId: decoded['channel_id'] as String,
        lastReadSeq: decoded['last_read_seq'] as int,
        manuallyUnread: decoded['manually_unread'] == true,
      ),
    'notification_override.changed' when decoded['channel_id'] is String =>
      NotificationOverrideChanged(
        channelId: decoded['channel_id'] as String,
        preference: decoded['preference'] is String
            ? NotificationPreference.parse(decoded['preference'] as String)
            : null,
      ),
    'message.components'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String &&
            decoded['components'] is List =>
      MessageComponentsChanged(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        components: ComponentRow.listFromJson(decoded['components']),
      ),
    'message.embeds'
        when decoded['channel_id'] is String &&
            decoded['message_id'] is String &&
            decoded['embeds'] is List =>
      MessageEmbedsChanged(
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String,
        embeds: [
          for (final e in decoded['embeds'] as List)
            Embed.fromJson(e as Map<String, dynamic>),
        ],
      ),
    'interaction.answered'
        when decoded['interaction_id'] is String &&
            decoded['channel_id'] is String =>
      InteractionAnswered(
        interactionId: decoded['interaction_id'] as String,
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String?,
      ),
    'interaction.form'
        when decoded['interaction_id'] is String &&
            decoded['channel_id'] is String &&
            decoded['form'] is Map<String, dynamic> =>
      InteractionForm(
        interactionId: decoded['interaction_id'] as String,
        channelId: decoded['channel_id'] as String,
        messageId: decoded['message_id'] as String?,
        botId: decoded['bot_id'] as String?,
        form: BotForm.fromJson(decoded['form'] as Map<String, dynamic>),
      ),
    'message.ephemeral'
        when decoded['channel_id'] is String &&
            decoded['message'] is Map<String, dynamic> =>
      MessageEphemeral(
        channelId: decoded['channel_id'] as String,
        message: EphemeralMessage.fromJson(
          decoded['message'] as Map<String, dynamic>,
        ),
      ),
    _ => null,
  };
}

/// Presence, member, role, channel and device frames.
ServerEvent? _rosterFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'presence.changed'
        when decoded['user_id'] is String &&
            _presenceStateOf(decoded['status']) != null =>
      PresenceChanged(
        userId: decoded['user_id'] as String,
        status: _presenceStateOf(decoded['status'])!,
        activity: PresenceActivity.tryFromJson(decoded['activity']),
        devices: PresenceDevice.parseAll(decoded['devices']),
      ),
    'member.timeout' when decoded['user_id'] is String => MemberTimeoutChanged(
        userId: decoded['user_id'] as String,
        // Absent and null both mean "no timeout", which is what a lift sends.
        until: decoded['until'] as int?,
      ),
    'join_gate.changed'
        when decoded['user_id'] == null || decoded['user_id'] is String =>
      JoinGateChanged(userId: decoded['user_id'] as String?),
    'member.removed' when decoded['user_id'] is String => MemberRemoved(
        userId: decoded['user_id'] as String,
      ),
    'member.restored' when decoded['user_id'] is String => MemberRestored(
        userId: decoded['user_id'] as String,
      ),
    'member.joined' when decoded['user_id'] is String => MemberJoined(
        userId: decoded['user_id'] as String,
      ),
    'profile.changed' when decoded['user_id'] is String => ProfileChanged(
        userId: decoded['user_id'] as String,
      ),
    'bot_ui.changed' when decoded['bot_user_id'] is String => BotUiChanged(
        botUserId: decoded['bot_user_id'] as String,
      ),
    'role.changed' when decoded['role_id'] is String => RoleChanged(
        roleId: decoded['role_id'] as String,
      ),
    'member.role_changed'
        when decoded['user_id'] is String && decoded['role_id'] is String =>
      MemberRoleChanged(
        userId: decoded['user_id'] as String,
        roleId: decoded['role_id'] as String,
      ),
    'channel.created' when decoded['channel'] is Map<String, dynamic> =>
      ChannelCreated(
        Channel.fromJson(decoded['channel'] as Map<String, dynamic>),
      ),
    'channel.updated' when decoded['channel'] is Map<String, dynamic> =>
      ChannelUpdated(
        Channel.fromJson(decoded['channel'] as Map<String, dynamic>),
      ),
    'channel.deleted' when decoded['channel_id'] is String => ChannelDeleted(
        channelId: decoded['channel_id'] as String,
      ),
    'overwrite.changed' when decoded['channel_id'] is String =>
      OverwriteChanged(channelId: decoded['channel_id'] as String),
    'device.signed_in'
        when decoded['device_id'] is String &&
            decoded['device_name'] is String &&
            decoded['signed_in_at'] is int =>
      NewDeviceSignIn(
        deviceId: decoded['device_id'] as String,
        deviceName: decoded['device_name'] as String,
        clientKind: decoded['client_kind'] as String?,
        signedInAt: decoded['signed_in_at'] as int,
      ),
    'voice.moved'
        when decoded['from_channel_id'] is String &&
            decoded['to_channel_id'] is String &&
            decoded['to_channel_name'] is String &&
            decoded['moved_by_id'] is String &&
            decoded['moved_by_name'] is String =>
      VoiceMoved(
        fromChannelId: decoded['from_channel_id'] as String,
        toChannelId: decoded['to_channel_id'] as String,
        toChannelName: decoded['to_channel_name'] as String,
        movedById: decoded['moved_by_id'] as String,
        movedByName: decoded['moved_by_name'] as String,
      ),
    _ => null,
  };
}

/// Voice, call and watch-party frames.
ServerEvent? _voiceFrame(Map<String, dynamic> decoded) {
  return switch (decoded['type']) {
    'voice.activity' when decoded['channel_id'] is String =>
      VoiceActivityChanged(channelId: decoded['channel_id'] as String),
    'voice.participant_joined'
        when decoded['channel_id'] is String && decoded['user_id'] is String =>
      VoiceParticipantJoined(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
      ),
    'voice.participant_left'
        when decoded['channel_id'] is String && decoded['user_id'] is String =>
      VoiceParticipantLeft(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
      ),
    'voice.screen_share_changed'
        when decoded['channel_id'] is String &&
            decoded['user_id'] is String &&
            decoded['is_sharing_screen'] is bool =>
      VoiceScreenShareChanged(
        channelId: decoded['channel_id'] as String,
        userId: decoded['user_id'] as String,
        isSharingScreen: decoded['is_sharing_screen'] as bool,
      ),
    'watch.tick'
        when decoded['channel_id'] is String &&
            decoded['bot_user_id'] is String &&
            decoded['ended'] is bool &&
            decoded['item_id'] is String &&
            decoded['playing'] is bool &&
            decoded['position_ms'] is int &&
            decoded['sampled_at_ms'] is int &&
            decoded['epoch'] is int =>
      WatchTick(
        channelId: decoded['channel_id'] as String,
        botUserId: decoded['bot_user_id'] as String,
        ended: decoded['ended'] as bool,
        itemId: decoded['item_id'] as String,
        playing: decoded['playing'] as bool,
        positionMs: decoded['position_ms'] as int,
        sampledAtMs: decoded['sampled_at_ms'] as int,
        epoch: decoded['epoch'] as int,
      ),
    'call.ringing'
        when decoded['channel_id'] is String &&
            decoded['ring_id'] is String &&
            decoded['caller_id'] is String =>
      CallRinging(
        channelId: decoded['channel_id'] as String,
        ringId: decoded['ring_id'] as String,
        callerId: decoded['caller_id'] as String,
      ),
    'call.ring_ended'
        when decoded['channel_id'] is String &&
            decoded['ring_id'] is String &&
            decoded['outcome'] is String &&
            CallOutcome.fromWire(decoded['outcome'] as String) != null =>
      CallRingEnded(
        channelId: decoded['channel_id'] as String,
        ringId: decoded['ring_id'] as String,
        outcome: CallOutcome.fromWire(decoded['outcome'] as String)!,
      ),
    _ => null,
  };
}
