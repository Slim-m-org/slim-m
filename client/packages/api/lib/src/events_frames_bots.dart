// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'events.dart';

// The bot-facing `ServerEvent` frames, split from `events_frames.dart` for the line budget.

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
