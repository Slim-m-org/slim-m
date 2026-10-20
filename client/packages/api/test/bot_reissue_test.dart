// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `POST /bots/{id}/token`: an administrator replaces a bot's token.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

void main() {
  test('re-issuing a bot token returns the bot and its new token', () async {
    final api = testApi((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/bots/b1/token');
      return http.Response(
        jsonEncode({
          'bot': {
            'user_id': 'b1',
            'username': 'helper',
            'display_name': 'helper',
            'created_at': 1,
            'permissions': 0,
            'online': false,
          },
          'token': 'slimbot_new',
        }),
        200,
      );
    });
    final reissued = await api.reissueBotToken('b1');
    expect(reissued.token, 'slimbot_new');
    expect(reissued.bot.userId, 'b1');
  });
}
