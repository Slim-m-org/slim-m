// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The event WebSocket: typed frames and the connection that carries them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'client.dart';
import 'models.dart';
import 'socket_liveness.dart';

part 'events_connection.dart';
part 'events_frames.dart';
part 'events_frames_bots.dart';
part 'events_frames_canvas.dart';
part 'events_frames_watch.dart';

/// The envelope version this client speaks. The server refuses a mismatch, so a
/// client that is too old fails at connect rather than misreading frames.
const int protocolVersion = 1;

/// An event pushed by the server.
sealed class ServerEvent {
  const ServerEvent();

  /// Parses a frame, or returns null for anything unrecognized. Unknown frame
  /// types (or a known type with a shape that does not parse) are ignored
  /// rather than fatal, so the server can add events without breaking older
  /// clients.
  static ServerEvent? parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final message = decoded['message'];
    return switch (decoded['type']) {
      'hello' => HelloEvent(protocol: decoded['protocol'] as int? ?? 0),
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
        ),
      'presence.changed'
          when decoded['user_id'] is String &&
              _presenceStateOf(decoded['status']) != null =>
        PresenceChanged(
          userId: decoded['user_id'] as String,
          status: _presenceStateOf(decoded['status'])!,
          activity: PresenceActivity.tryFromJson(decoded['activity']),
          devices: PresenceDevice.parseAll(decoded['devices']),
        ),
      'member.timeout' when decoded['user_id'] is String =>
        MemberTimeoutChanged(
          userId: decoded['user_id'] as String,
          // Absent and null both mean "no timeout", which is what a lift sends.
          until: decoded['until'] as int?,
        ),
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
      'typing.started'
          when decoded['channel_id'] is String &&
              decoded['user_id'] is String =>
        TypingStarted(
          channelId: decoded['channel_id'] as String,
          userId: decoded['user_id'] as String,
        ),
      'typing.stopped'
          when decoded['channel_id'] is String &&
              decoded['user_id'] is String =>
        TypingStopped(
          channelId: decoded['channel_id'] as String,
          userId: decoded['user_id'] as String,
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
      'category.changed' => const CategoryChanged(),
      'voice.activity' when decoded['channel_id'] is String =>
        VoiceActivityChanged(channelId: decoded['channel_id'] as String),
      'voice.participant_joined'
          when decoded['channel_id'] is String &&
              decoded['user_id'] is String =>
        VoiceParticipantJoined(
          channelId: decoded['channel_id'] as String,
          userId: decoded['user_id'] as String,
        ),
      'voice.participant_left'
          when decoded['channel_id'] is String &&
              decoded['user_id'] is String =>
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
      'reports.changed' => const ReportsChanged(),
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
      'interaction.answered'
          when decoded['interaction_id'] is String &&
              decoded['channel_id'] is String =>
        InteractionAnswered(
          interactionId: decoded['interaction_id'] as String,
          channelId: decoded['channel_id'] as String,
          messageId: decoded['message_id'] as String?,
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
      'canvas.object.placed'
          when decoded['channel_id'] is String &&
              decoded['object'] is Map<String, dynamic> =>
        CanvasObjectPlaced(
          channelId: decoded['channel_id'] as String,
          object: CanvasObject.fromJson(
            decoded['object'] as Map<String, dynamic>,
          ),
        ),
      'canvas.objects.removed'
          when decoded['channel_id'] is String &&
              decoded['seq'] is int &&
              decoded['op_id'] is String &&
              decoded['object_ids'] is List =>
        CanvasObjectsRemoved(
          channelId: decoded['channel_id'] as String,
          seq: decoded['seq'] as int,
          opId: decoded['op_id'] as String,
          objectIds: (decoded['object_ids'] as List<dynamic>).cast<String>(),
        ),
      'canvas.cleared'
          when decoded['channel_id'] is String &&
              decoded['seq'] is int &&
              decoded['op_id'] is String &&
              decoded['before_seq'] is int =>
        CanvasCleared(
          channelId: decoded['channel_id'] as String,
          seq: decoded['seq'] as int,
          opId: decoded['op_id'] as String,
          beforeSeq: decoded['before_seq'] as int,
        ),
      'canvas.objects.restored'
          when decoded['channel_id'] is String &&
              decoded['seq'] is int &&
              decoded['op_id'] is String &&
              decoded['object_ids'] is List =>
        CanvasObjectsRestored(
          channelId: decoded['channel_id'] as String,
          seq: decoded['seq'] as int,
          opId: decoded['op_id'] as String,
          objectIds: (decoded['object_ids'] as List<dynamic>).cast<String>(),
        ),
      'canvas.cursor.moved'
          when decoded['channel_id'] is String &&
              decoded['user_id'] is String &&
              decoded['x'] is num &&
              decoded['y'] is num =>
        CanvasCursorMoved(
          channelId: decoded['channel_id'] as String,
          userId: decoded['user_id'] as String,
          x: (decoded['x'] as num).toDouble(),
          y: (decoded['y'] as num).toDouble(),
        ),
      'canvas.stroke_preview.updated'
          when decoded['channel_id'] is String &&
              decoded['user_id'] is String &&
              decoded['object_id'] is String &&
              decoded['points'] is List &&
              decoded['ended'] is bool =>
        CanvasStrokePreview(
          channelId: decoded['channel_id'] as String,
          userId: decoded['user_id'] as String,
          objectId: decoded['object_id'] as String,
          points: (decoded['points'] as List<dynamic>)
              .map((p) => (p as num).toDouble())
              .toList(growable: false),
          ended: decoded['ended'] as bool,
        ),
      'canvas.object.moved'
          when decoded['channel_id'] is String &&
              decoded['seq'] is int &&
              decoded['op_id'] is String &&
              decoded['object_id'] is String &&
              decoded['x'] is num &&
              decoded['y'] is num &&
              decoded['w'] is num &&
              decoded['h'] is num =>
        CanvasObjectMoved(
          channelId: decoded['channel_id'] as String,
          seq: decoded['seq'] as int,
          opId: decoded['op_id'] as String,
          objectId: decoded['object_id'] as String,
          x: (decoded['x'] as num).toDouble(),
          y: (decoded['y'] as num).toDouble(),
          w: (decoded['w'] as num).toDouble(),
          h: (decoded['h'] as num).toDouble(),
        ),
      'canvas.object.reordered'
          when decoded['channel_id'] is String &&
              decoded['seq'] is int &&
              decoded['op_id'] is String &&
              decoded['object_id'] is String &&
              decoded['z_index'] is int =>
        CanvasObjectReordered(
          channelId: decoded['channel_id'] as String,
          seq: decoded['seq'] as int,
          opId: decoded['op_id'] as String,
          objectId: decoded['object_id'] as String,
          zIndex: decoded['z_index'] as int,
        ),
      'canvas.media_slot.changed'
          when decoded['channel_id'] is String &&
              decoded['kind'] is String &&
              decoded['user_id'] is String &&
              decoded['x'] is num &&
              decoded['y'] is num &&
              decoded['w'] is num &&
              decoded['h'] is num &&
              decoded['locked'] is bool &&
              decoded['sent_to_back'] is bool =>
        CanvasMediaSlotChanged(
          channelId: decoded['channel_id'] as String,
          kind: decoded['kind'] as String,
          userId: decoded['user_id'] as String,
          x: (decoded['x'] as num).toDouble(),
          y: (decoded['y'] as num).toDouble(),
          w: (decoded['w'] as num).toDouble(),
          h: (decoded['h'] as num).toDouble(),
          locked: decoded['locked'] as bool,
          sentToBack: decoded['sent_to_back'] as bool,
        ),
      'pong' => const PongEvent(),
      'error' => ErrorEvent(decoded['message'] as String? ?? 'unknown'),
      _ => null,
    };
  }
}

/// Resolves a frame's raw `status` string to a known [PresenceState], or null
/// for anything else (including a non-string), so a future server addition
/// is ignored the same way an unrecognized frame type is rather than
/// throwing out of an enum lookup.
PresenceState? _presenceStateOf(Object? raw) =>
    PresenceState.values.where((s) => s.name == raw).firstOrNull;

/// The server accepted the handshake.
class HelloEvent extends ServerEvent {
  const HelloEvent({required this.protocol});

  final int protocol;
}

/// A message was posted in a channel this session can view.
class MessageCreated extends ServerEvent {
  const MessageCreated(this.message);

  final Message message;
}

/// A message was edited.
class MessageEdited extends ServerEvent {
  const MessageEdited(this.message, {this.opSeq});

  final Message message;

  /// This edit's place in the channel's message-op stream, null against a
  /// server that has none.
  ///
  /// A different number in a different sequence from `message.seq`, which is
  /// the message's own creation order and is unmoved by an edit. The two
  /// sitting adjacent in one frame is the obvious thing to conflate.
  final int? opSeq;
}

/// Keepalive reply.
class PongEvent extends ServerEvent {
  const PongEvent();
}

/// A terminal condition. `resync` means the connection fell behind and was
/// closed, so reconnect and catch up over sync.
class ErrorEvent extends ServerEvent {
  const ErrorEvent(this.message);

  final String message;

  bool get needsResync => message == 'resync';
}
