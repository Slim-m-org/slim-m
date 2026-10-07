// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Menu entries and call controls a bot adds to the app. See
/// docs/decisions/0045-bot-contributed-ui.md.
library;

/// One entry a bot registered: a row in a message's menu, or a control in a
/// call. [id] is what the bot gets back when it is used.
class BotUiEntry {
  const BotUiEntry({
    required this.id,
    required this.label,
    this.icon,
    this.options = const [],
  });

  final String id;
  final String label;

  /// A call control's glyph name, from a fixed list the server checks; the
  /// app draws it, so a bot never supplies a picture.
  final String? icon;

  /// The choices a call control offers; empty for a plain button. Using one
  /// sends the chosen option's id.
  final List<BotUiOption> options;

  factory BotUiEntry.fromJson(Map<String, dynamic> json) => BotUiEntry(
        id: json['id'] as String,
        label: json['label'] as String,
        icon: json['icon'] as String?,
        options: (json['options'] as List<dynamic>? ?? [])
            .map((o) => BotUiOption.fromJson(o as Map<String, dynamic>))
            .toList(growable: false),
      );
}

/// One choice a call control offers, such as a stream quality.
class BotUiOption {
  const BotUiOption({required this.id, required this.label});

  final String id;
  final String label;

  factory BotUiOption.fromJson(Map<String, dynamic> json) => BotUiOption(
        id: json['id'] as String,
        label: json['label'] as String,
      );
}

/// What one bot adds in a channel, from `GET /channels/{channelId}/bot-ui`;
/// already filtered to bots that can see the channel and to entries the
/// caller may use.
class ChannelBotUi {
  const ChannelBotUi({
    required this.botUserId,
    required this.botUsername,
    required this.botDisplayName,
    required this.messageMenu,
    required this.callControls,
  });

  final String botUserId;
  final String botUsername;
  final String botDisplayName;
  final List<BotUiEntry> messageMenu;
  final List<BotUiEntry> callControls;

  factory ChannelBotUi.fromJson(Map<String, dynamic> json) => ChannelBotUi(
        botUserId: json['bot_user_id'] as String,
        botUsername: json['bot_username'] as String,
        botDisplayName: json['bot_display_name'] as String,
        messageMenu: _entries(json['message_menu']),
        callControls: _entries(json['call_controls']),
      );

  static List<BotUiEntry> _entries(Object? raw) => (raw as List<dynamic>? ?? [])
      .map((e) => BotUiEntry.fromJson(e as Map<String, dynamic>))
      .toList(growable: false);
}
