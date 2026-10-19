// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:test/test.dart';
import 'package:slimm_api/api.dart';

void main() {
  test('a channel command reads its options and their choices', () {
    final command = ChannelBotCommand.fromJson({
      'bot_user_id': 'b',
      'bot_username': 'deals',
      'bot_display_name': 'Deals',
      'prefix': '!',
      'name': 'sources',
      'description': 'pick a store',
      'options': [
        {
          'name': 'source',
          'required': true,
          'choices': ['steam', 'gog'],
        },
        {'name': 'note'},
      ],
    });
    expect(command.options.first.choices, ['steam', 'gog']);
    expect(command.options.first.required, isTrue);
    expect(command.options.last.choices, isEmpty);
  });

  test('a command without options reads an empty list', () {
    final command = RegisteredBotCommand.fromJson({
      'name': 'ping',
      'description': 'pong',
    });
    expect(command.options, isEmpty);
  });
}
