// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// One bot, as the admin surface lists it. Never carries a token.
class Bot {
  const Bot({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.createdAt,
    required this.permissions,
    this.tokenName,
    this.tokenLastUsedAt,
    this.roleId,
    this.prefix,
    this.online = false,
  });

  factory Bot.fromJson(Map<String, dynamic> json) => Bot(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String,
        createdAt: json['created_at'] as int,
        tokenName: json['token_name'] as String?,
        tokenLastUsedAt: json['token_last_used_at'] as int?,
        roleId: json['role_id'] as String?,
        permissions: json['permissions'] as int,
        prefix: json['prefix'] as String?,
        online: json['online'] as bool? ?? false,
      );

  final String userId;
  final String username;
  final String displayName;
  final int createdAt;

  /// Null once the token is revoked, which is how a reader tells a live bot
  /// from one that is only still listed for its authorship.
  final String? tokenName;

  /// Written at most once a minute server-side, so it is a recency hint and
  /// not an exact last-call time.
  final int? tokenLastUsedAt;

  /// The bot's managed role.
  final String? roleId;

  /// What the managed role currently grants.
  final int permissions;

  /// The command prefix assigned to this bot; null until one is assigned.
  final String? prefix;

  /// The bot holds a live socket right now, hidden or not.
  final bool online;

  bool get isRevoked => tokenName == null;
}

/// A freshly created bot, and the only time its token is ever legible.
class NewBot {
  const NewBot({required this.bot, required this.token});

  factory NewBot.fromJson(Map<String, dynamic> json) => NewBot(
        bot: Bot.fromJson(json['bot'] as Map<String, dynamic>),
        token: json['token'] as String,
      );

  final Bot bot;

  /// Shown once and unrecoverable afterwards: the server stores only a hash.
  final String token;
}

/// Bots: provisioning, listing and revoking, the `bots` tag.
///
/// All three need MANAGE_SERVER, and creating one additionally needs the caller
/// not to be a bot - see `docs/decisions/0028-bot-accounts.md` for why a bot
/// may not provision a bot.
extension SlimmApiBots on SlimmApi {
  /// Bots in the deployment, newest first. A revoked bot that is still a
  /// member is still listed; one also removed from the Space is not, unless
  /// [includeRemoved] is true - it is already gone from [listMembers].
  Future<List<Bot>> listBots({bool includeRemoved = false}) async {
    final json = await _send(
      'GET',
      '/bots',
      query: includeRemoved ? const {'include_removed': 'true'} : null,
    );
    return (json as List<dynamic>)
        .map((entry) => Bot.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Creates a bot and returns it with its token, shown only this once.
  Future<NewBot> createBot(
    String username, {
    String? displayName,
    int permissions = 0,
    String? prefix,
  }) async {
    final json = await _send(
      'POST',
      '/bots',
      body: {
        'username': username,
        if (displayName != null) 'display_name': displayName,
        'permissions': permissions,
        if (prefix != null) 'prefix': prefix,
      },
    );
    return NewBot.fromJson(json as Map<String, dynamic>);
  }

  /// A command prefix no live bot holds, for the create form to offer.
  Future<String> suggestedBotPrefix() async {
    final json = await _send('GET', '/bots/suggested-prefix');
    return (json as Map<String, dynamic>)['prefix'] as String;
  }

  /// A member's effective permission bits. Bot accounts only, so the app never
  /// calls it; it is here for the wire contract.
  Future<int> memberPermissions(String userId) async {
    final json = await _send('GET', '/members/$userId/permissions');
    return (json as Map<String, dynamic>)['permissions'] as int;
  }

  /// Revokes a bot's token and session, stopping it on its next request.
  Future<void> revokeBot(String botUserId) =>
      _send('POST', '/bots/$botUserId/revoke', expectNoContent: true);

  /// Replaces a bot's token and returns the new one, shown only this once.
  Future<NewBot> reissueBotToken(String botUserId) async {
    final json = await _send('POST', '/bots/$botUserId/token');
    return NewBot.fromJson(json as Map<String, dynamic>);
  }

  /// Replaces what a bot's managed role grants.
  Future<Bot> setBotPermissions(String botUserId, int permissions) async {
    final json = await _send(
      'PATCH',
      '/bots/$botUserId/permissions',
      body: {'permissions': permissions},
    );
    return Bot.fromJson(json as Map<String, dynamic>);
  }

  /// Moves a bot to another command prefix; refused with a 409 naming the
  /// commands another live bot already answers to under it.
  Future<Bot> setBotPrefix(String botUserId, String prefix) async {
    final json = await _send(
      'PATCH',
      '/bots/$botUserId/prefix',
      body: {'prefix': prefix},
    );
    return Bot.fromJson(json as Map<String, dynamic>);
  }
}
