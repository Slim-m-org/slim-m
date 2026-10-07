// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('bot_ui.changed decodes to BotUiChanged carrying only the bot', () {
    final event = ServerEvent.parse(
      jsonEncode({'type': 'bot_ui.changed', 'bot_user_id': 'b'}),
    );
    expect(event, isA<BotUiChanged>());
    expect((event! as BotUiChanged).botUserId, 'b');
  });

  test('a bot_ui.changed frame missing bot_user_id is ignored, not a crash',
      () {
    expect(ServerEvent.parse(jsonEncode({'type': 'bot_ui.changed'})), isNull);
  });
}
