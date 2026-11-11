// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An account a member linked from elsewhere (`LinkedAccount` in the schema).
library;

/// Who a member is on another service. Discord and Steam.
class LinkedAccount {
  const LinkedAccount({
    required this.provider,
    required this.username,
    required this.linkedAt,
    this.displayName,
    this.avatarUpdatedAt,
    this.shareActivity = false,
  });

  factory LinkedAccount.fromJson(Map<String, dynamic> json) => LinkedAccount(
        provider: json['provider'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String?,
        linkedAt: json['linked_at'] as int,
        avatarUpdatedAt: json['avatar_updated_at'] as int?,
        shareActivity: json['share_activity'] as bool? ?? false,
      );

  final String provider;
  final String username;
  final String? displayName;
  final int linkedAt;

  /// Null when the server stored no picture; also the cache key for one.
  final int? avatarUpdatedAt;

  /// Whether the member shows the game they play (Steam only).
  final bool shareActivity;

  bool get isSteam => provider == LinkedAccount.steam;

  bool get isDiscord => provider == LinkedAccount.discord;

  static const discord = 'discord';
  static const steam = 'steam';
}
