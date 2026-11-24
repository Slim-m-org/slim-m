// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

// The bot- and module-facing `ServerEvent` frames and those for one account's own sockets, split from `events_frames.dart` for the line budget.

/// A bot answered this account privately. Delivered only to the account's own
/// sockets and never replayed, so a receiver keeps it in memory and drops it
/// on dismissal or reload. See docs/decisions/0037-ephemeral-bot-messages.md.
class MessageEphemeral extends ServerEvent {
  const MessageEphemeral({required this.channelId, required this.message});

  final String channelId;
  final EphemeralMessage message;
}

/// A bot replaced or cleared the buttons on its message. Carries the whole
/// current list, so a receiver replaces rather than merges.
class MessageComponentsChanged extends ServerEvent {
  const MessageComponentsChanged({
    required this.channelId,
    required this.messageId,
    required this.components,
  });

  final String channelId;
  final String messageId;
  final List<ComponentRow> components;
}

/// A bot replaced or cleared the embeds on its message by editing it; the
/// whole current list, so a receiver replaces rather than merges.
class MessageEmbedsChanged extends ServerEvent {
  const MessageEmbedsChanged({
    required this.channelId,
    required this.messageId,
    required this.embeds,
  });

  final String channelId;
  final String messageId;
  final List<Embed> embeds;
}

/// A voice message's transcript started, finished or failed. Lossy: reading
/// the message is the catch-up.
class MessageVoiceTranscript extends ServerEvent {
  const MessageVoiceTranscript({
    required this.channelId,
    required this.messageId,
    required this.attachmentId,
    required this.transcript,
  });

  final String channelId;
  final String messageId;
  final String attachmentId;
  final VoiceTranscript transcript;
}

/// The bot answered this account's button press, so the button can stop
/// showing as pending. See docs/decisions/0039-bot-message-buttons.md.
class InteractionAnswered extends ServerEvent {
  const InteractionAnswered({
    required this.interactionId,
    required this.channelId,
    this.messageId,
  });

  final String interactionId;
  final String channelId;

  /// Absent when the answered use was a call control, which names no message.
  final String? messageId;
}

/// A bot opened a form for this account's press. The press counts as answered
/// and the client shows [form]; submitting it names [interactionId]. See
/// docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.
class InteractionForm extends ServerEvent {
  const InteractionForm({
    required this.interactionId,
    required this.channelId,
    required this.form,
    this.messageId,
    this.botId,
  });

  final String interactionId;
  final String channelId;
  final String? messageId;
  final BotForm form;

  /// Absent from an older server, which did not say which bot opened the form.
  final String? botId;
}

/// A module's room state in [channelId] changed (decision 0131), or the room
/// ended when [state] is null; [ended] then says how (`ended`, `call_ended`,
/// `channel_removed`, `module_off`, `idle`).
class ModuleRoomChanged extends ServerEvent {
  const ModuleRoomChanged({
    required this.channelId,
    required this.moduleId,
    required this.seq,
    required this.state,
    this.scene,
    this.ended,
  });

  final String channelId;
  final String moduleId;
  final int seq;
  final Object? state;

  /// See [roomSceneText].
  final String? scene;
  final String? ended;
}

/// Someone started a call, joined one or went live in a voice channel this account asked to
/// hear about. Delivered only to that account, after the server applied every exclusion.
class VoiceNotice extends ServerEvent {
  const VoiceNotice({
    required this.channelId,
    required this.actorId,
    required this.activity,
  });

  final String channelId;
  final String actorId;
  final VoiceActivity activity;
}

enum VoiceActivity {
  /// The first person joined an empty channel.
  callStarted,
  joined,
  streaming,
}

/// A moderator moved this account to another voice channel. Delivered only to
/// the moved account's sockets.
class VoiceMoved extends ServerEvent {
  const VoiceMoved({
    required this.fromChannelId,
    required this.toChannelId,
    required this.toChannelName,
    required this.movedById,
    required this.movedByName,
  });

  final String fromChannelId;
  final String toChannelId;
  final String toChannelName;
  final String movedById;
  final String movedByName;
}

/// A device this account has not used before just signed in. Delivered only
/// to the account's other sockets, never to the device that signed in.
class NewDeviceSignIn extends ServerEvent {
  const NewDeviceSignIn({
    required this.deviceId,
    required this.deviceName,
    required this.signedInAt,
    this.clientKind,
  });

  final String deviceId;
  final String deviceName;

  /// "ios", "android", "desktop" or "web", or null when the device did not say.
  final String? clientKind;

  /// Unix milliseconds.
  final int signedInAt;
}
