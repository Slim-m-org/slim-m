// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bot command registration wire shapes. See
/// docs/decisions/0031-bot-command-registration.md.
library;

import 'models_attachments.dart';
import 'models_embeds.dart';

/// One positional argument of a bot command; [choices] empty means free form.
class BotCommandOption {
  const BotCommandOption({
    required this.name,
    this.required = false,
    this.choices = const [],
  });

  final String name;
  final bool required;
  final List<String> choices;

  factory BotCommandOption.fromJson(Map<String, dynamic> json) =>
      BotCommandOption(
        name: json['name'] as String,
        required: json['required'] as bool? ?? false,
        choices: (json['choices'] as List<dynamic>? ?? const [])
            .cast<String>()
            .toList(growable: false),
      );
}

List<BotCommandOption> _optionsFromJson(Object? json) =>
    (json as List<dynamic>? ?? const [])
        .map((o) => BotCommandOption.fromJson(o as Map<String, dynamic>))
        .toList(growable: false);

/// One bot command offered in a channel, from `GET
/// /channels/{channelId}/bot-commands`; already permission- and
/// visibility-filtered server-side.
class ChannelBotCommand {
  const ChannelBotCommand({
    required this.botUserId,
    required this.botUsername,
    required this.botDisplayName,
    required this.prefix,
    required this.name,
    required this.description,
    this.usage,
    this.options = const [],
    this.offline = false,
  });

  final String botUserId;
  final String botUsername;
  final String botDisplayName;

  /// What this bot answers to, e.g. `!` or `?`; never `/`, `@` or `:`.
  final String prefix;

  /// The bare keyword after [prefix]; the composer inserts `$prefix$name `.
  final String name;
  final String description;
  final String? usage;

  /// Positional arguments; the composer picks from [BotCommandOption.choices].
  final List<BotCommandOption> options;

  /// The bot has no live socket, so the command would get no answer.
  final bool offline;

  factory ChannelBotCommand.fromJson(Map<String, dynamic> json) =>
      ChannelBotCommand(
        botUserId: json['bot_user_id'] as String,
        botUsername: json['bot_username'] as String,
        botDisplayName: json['bot_display_name'] as String,
        prefix: json['prefix'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        usage: json['usage'] as String?,
        options: _optionsFromJson(json['options']),
        offline: json['offline'] as bool? ?? false,
      );
}

/// One entry of a bot's own registered set, from `GET /bots/{botId}/commands`.
class RegisteredBotCommand {
  const RegisteredBotCommand({
    required this.name,
    required this.description,
    this.usage,
    this.options = const [],
  });

  final String name;
  final String description;
  final String? usage;
  final List<BotCommandOption> options;

  factory RegisteredBotCommand.fromJson(Map<String, dynamic> json) =>
      RegisteredBotCommand(
        name: json['name'] as String,
        description: json['description'] as String,
        usage: json['usage'] as String?,
        options: _optionsFromJson(json['options']),
      );
}

/// A bot's whole registration, for its profile. Null [prefix] means it has
/// never registered anything.
class BotCommandRegistration {
  const BotCommandRegistration({required this.prefix, required this.commands});

  final String? prefix;
  final List<RegisteredBotCommand> commands;

  factory BotCommandRegistration.fromJson(Map<String, dynamic> json) =>
      BotCommandRegistration(
        prefix: json['prefix'] as String?,
        commands: (json['commands'] as List<dynamic>)
            .map(
                (c) => RegisteredBotCommand.fromJson(c as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// A bot's private answer to this account, from the `message.ephemeral`
/// frame. Not a stored message: it has no `seq` and cannot be fetched again.
/// See docs/decisions/0037-ephemeral-bot-messages.md.
class EphemeralMessage {
  const EphemeralMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.authorDisplayName,
    required this.content,
    required this.inReplyToId,
    required this.createdAt,
    this.attachments = const [],
    this.embeds = const [],
  });

  final String id;
  final String channelId;
  final String authorId;
  final String authorDisplayName;
  final String content;
  final String inReplyToId;
  final int createdAt;

  /// Files that were already fetchable; the message itself owns no bytes.
  final List<Attachment> attachments;
  final List<Embed> embeds;

  factory EphemeralMessage.fromJson(Map<String, dynamic> json) =>
      EphemeralMessage(
        id: json['id'] as String,
        channelId: json['channel_id'] as String,
        authorId: json['author_id'] as String,
        authorDisplayName: json['author_display_name'] as String,
        content: json['content'] as String,
        inReplyToId: json['in_reply_to_id'] as String,
        createdAt: json['created_at'] as int,
        attachments: (json['attachments'] as List<dynamic>?)
                ?.map((a) => Attachment.fromJson(a as Map<String, dynamic>))
                .toList(growable: false) ??
            const [],
        embeds: (json['embeds'] as List<dynamic>?)
                ?.map((e) => Embed.fromJson(e as Map<String, dynamic>))
                .toList(growable: false) ??
            const [],
      );
}
