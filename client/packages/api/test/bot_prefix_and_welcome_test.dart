// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's assigned prefix, the suggested-prefix route and the welcome fields
/// on the Space settings, as the client sends and reads them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

SlimmApi _api(Future<http.Response> Function(http.Request) handler) =>
    testApi(handler,
        session: SessionStore(
          tokens: const TokenPair(
            userId: 'u1',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ));

const _bot = {
  'user_id': 'b1',
  'username': 'jelly',
  'display_name': 'Jelly',
  'created_at': 1,
  'permissions': 0,
  'prefix': '~',
};

void main() {
  test('createBot sends the chosen prefix and reads the assigned one back',
      () async {
    late Map<String, dynamic> body;
    final api = _api((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'bot': _bot, 'token': 't'}), 201);
    });
    final created = await api.createBot('jelly', prefix: '~');
    expect(body['prefix'], '~');
    expect(created.bot.prefix, '~');
  });

  test('createBot leaves the prefix out so the server picks one', () async {
    late Map<String, dynamic> body;
    final api = _api((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'bot': _bot, 'token': 't'}), 201);
    });
    await api.createBot('jelly');
    expect(body.containsKey('prefix'), isFalse);
  });

  test('a bot from an older server has no prefix', () {
    final bot = Bot.fromJson({..._bot}..remove('prefix'));
    expect(bot.prefix, isNull);
  });

  test('suggestedBotPrefix reads the free prefix', () async {
    final api = _api((request) async {
      expect(request.url.path, '/bots/suggested-prefix');
      return http.Response(jsonEncode({'prefix': '?'}), 200);
    });
    expect(await api.suggestedBotPrefix(), '?');
  });

  test('setBotPrefix patches the bot and reads the moved bot back', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(jsonEncode({..._bot, 'prefix': '?'}), 200);
    });
    final moved = await api.setBotPrefix('b1', '?');
    expect(seen.method, 'PATCH');
    expect(seen.url.path, '/bots/b1/prefix');
    expect(jsonDecode(seen.body), {'prefix': '?'});
    expect(moved.prefix, '?');
  });

  test('setBotPrefix surfaces a clash as a conflict', () async {
    final api = _api((request) async => http.Response(
        jsonEncode({'error': 'another bot already answers to watch under !'}),
        409));
    expect(api.setBotPrefix('b1', '!'), throwsA(isA<ConflictException>()));
  });

  test('memberPermissions reads one member\'s bits', () async {
    final api = _api((request) async {
      expect(request.url.path, '/members/u2/permissions');
      return http.Response(
          jsonEncode({'user_id': 'u2', 'permissions': 6}), 200);
    });
    expect(await api.memberPermissions('u2'), 6);
  });

  test('space settings read the welcome fields and default them off', () {
    final set = SpaceSettings.fromJson({
      'join_policy': 'invite',
      'welcome_enabled': true,
      'welcome_channel_id': 'c1',
      'welcome_message': 'hi {user}',
    });
    expect(set.welcomeEnabled, isTrue);
    expect(set.welcomeChannelId, 'c1');
    expect(set.welcomeMessage, 'hi {user}');
    final old = SpaceSettings.fromJson({'join_policy': 'invite'});
    expect(old.welcomeEnabled, isFalse);
    expect(old.welcomeChannelId, isNull);
    expect(old.welcomeMessage, '');
  });

  test('setSpaceSettings sends only the welcome fields it is given', () async {
    late Map<String, dynamic> body;
    final api = _api((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'join_policy': 'invite'}), 200);
    });
    await api.setSpaceSettings(
        const SpaceSettingsUpdate(welcomeEnabled: false, welcomeChannelId: ''));
    expect(body, {'welcome_enabled': false, 'welcome_channel_id': ''});
  });
}
