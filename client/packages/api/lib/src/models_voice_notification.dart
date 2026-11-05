// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member's opt-in to hear when a voice channel's call starts, grows or goes live
/// (`GET /voice-notifications/channels`).
library;

/// How much of a call's joins a member wants to hear about.
enum VoiceJoinMode {
  off,

  /// Only the join that starts a call in an empty channel.
  first,
  every;

  String get wire => name;

  /// An unrecognised value reads as [off]: nothing is sent unless asked for.
  static VoiceJoinMode parse(String value) => switch (value) {
        'first' => VoiceJoinMode.first,
        'every' => VoiceJoinMode.every,
        _ => VoiceJoinMode.off,
      };
}

/// One voice channel's choice.
class VoiceNotification {
  const VoiceNotification({
    required this.channelId,
    required this.joins,
    required this.streams,
  });

  final String channelId;
  final VoiceJoinMode joins;

  /// Whether to hear when someone starts sharing their screen.
  final bool streams;

  factory VoiceNotification.fromJson(Map<String, dynamic> json) =>
      VoiceNotification(
        channelId: json['channel_id'] as String,
        joins: VoiceJoinMode.parse(json['joins'] as String),
        streams: json['streams'] as bool,
      );
}
