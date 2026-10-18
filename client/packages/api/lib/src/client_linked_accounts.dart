// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Linking accounts from other services to a member's profile.
extension SlimmApiLinkedAccounts on SlimmApi {
  Future<List<LinkedAccount>> myLinkedAccounts() async {
    final json = await _send('GET', '/me/links');
    return _linkedAccounts(json);
  }

  /// The accounts [userId] linked, for their profile card.
  Future<List<LinkedAccount>> linkedAccountsOf(String userId) async {
    final json = await _send('GET', '/users/$userId/links');
    return _linkedAccounts(json);
  }

  /// Discord's authorize URL, to open in a browser. Throws
  /// [NotConfiguredException] when the server has no Discord application.
  Future<String> startDiscordLink() async {
    final json = await _send('POST', '/me/links/discord/start');
    return (json as Map<String, dynamic>)['url'] as String;
  }

  Future<void> unlinkDiscord() =>
      _send('DELETE', '/me/links/discord', expectNoContent: true);

  List<LinkedAccount> _linkedAccounts(Object? json) => [
        for (final item in json as List<dynamic>)
          LinkedAccount.fromJson(item as Map<String, dynamic>),
      ];
}
