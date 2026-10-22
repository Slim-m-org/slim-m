// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Buttons on a message and the two frames that concern them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

const _buttons = [
  {
    'buttons': [
      {'label': 'Hit', 'style': 'primary', 'custom_id': 'hit'},
      {
        'label': 'Stand',
        'style': 'secondary',
        'custom_id': 'stand',
        'disabled': true,
      },
      {'label': 'Rules', 'style': 'link', 'url': 'https://example.com'},
    ],
  },
];

void main() {
  test('a message carries its rows of buttons', () {
    final message = Message.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'seq': 1,
      'content': 'your move',
      'created_at': 1,
      'components': _buttons,
    });
    final row = message.components.single;
    expect(row.buttons.map((b) => b.label), ['Hit', 'Stand', 'Rules']);
    expect(row.buttons[0].style, ComponentButtonStyle.primary);
    expect(row.buttons[0].customId, 'hit');
    expect(row.buttons[1].disabled, isTrue);
    expect(row.buttons[2].style, ComponentButtonStyle.link);
    expect(row.buttons[2].customId, isNull);
    expect(row.buttons[2].url, 'https://example.com');
  });

  test('a message with no components field has none', () {
    final message = Message.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'seq': 1,
      'content': 'hi',
      'created_at': 1,
    });
    expect(message.components, isEmpty);
  });

  test('an unknown style still renders as a pressable button', () {
    final button = MessageButton.fromJson({
      'label': 'x',
      'style': 'success',
      'custom_id': 'x',
    });
    expect(button.style, ComponentButtonStyle.secondary);
  });

  test('parses message.components, including a clear', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'message.components',
        'channel_id': 'c1',
        'message_id': 'm1',
        'components': <Object>[],
      }),
    );
    expect(event, isA<MessageComponentsChanged>());
    expect((event as MessageComponentsChanged).components, isEmpty);
    expect(event.messageId, 'm1');
  });

  test('parses interaction.answered', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'interaction.answered',
        'interaction_id': 'i1',
        'channel_id': 'c1',
        'message_id': 'm1',
      }),
    );
    expect(event, isA<InteractionAnswered>());
    expect((event as InteractionAnswered).interactionId, 'i1');
  });

  test('a components frame with no list is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'message.components',
        'channel_id': 'c1',
        'message_id': 'm1',
      }),
    );
    expect(event, isNull);
  });

  test('a row carries one select menu, with its bounds defaulted', () {
    final message = Message.fromJson({
      'id': 'm1',
      'channel_id': 'c1',
      'seq': 1,
      'content': 'when?',
      'created_at': 1,
      'components': [
        {
          'buttons': <Object>[],
          'select': {
            'custom_id': 'day',
            'placeholder': 'Pick a day',
            'options': [
              {'label': 'Monday', 'value': 'mon', 'description': 'first'},
              {'label': 'Tuesday', 'value': 'tue'},
            ],
          },
        },
      ],
    });
    final select = message.components.single.select!;
    expect(select.customId, 'day');
    expect(select.placeholder, 'Pick a day');
    expect(select.options.map((o) => o.value), ['mon', 'tue']);
    expect(select.options.first.description, 'first');
    expect(select.picksOne, isTrue);
    expect(message.components.single.buttons, isEmpty);
  });

  test('parses interaction.form', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'interaction.form',
        'interaction_id': 'i1',
        'channel_id': 'c1',
        'message_id': 'm1',
        'bot_id': 'b1',
        'form': {
          'custom_id': 'remind',
          'title': 'Remind me',
          'fields': [
            {'custom_id': 'what', 'label': 'What'},
            {
              'custom_id': 'note',
              'label': 'Note',
              'required': false,
              'multiline': true,
              'max_length': 80,
            },
          ],
        },
      }),
    );
    final form = (event as InteractionForm).form;
    expect(event.interactionId, 'i1');
    expect(event.botId, 'b1');
    expect(form.title, 'Remind me');
    expect(form.fields[0].required, isTrue);
    expect(form.fields[0].maxLength, 200);
    expect(form.fields[1].required, isFalse);
    expect(form.fields[1].multiline, isTrue);
    expect(form.fields[1].maxLength, 80);
  });

  test('a form frame without a form is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'interaction.form',
        'interaction_id': 'i1',
        'channel_id': 'c1',
      }),
    );
    expect(event, isNull);
  });

  test('choosing sends the values and submitting sends the fields', () async {
    final sent = <String, Object?>{};
    final api = testApi((request) async {
      sent['${request.method} ${request.url.path}'] = jsonDecode(request.body);
      return http.Response('{"id":"x","created_at":1}', 200);
    });
    await api.pressMessageButton(
      channelId: 'c1',
      messageId: 'm1',
      id: 'p1',
      customId: 'day',
      values: ['mon', 'tue'],
    );
    await api.submitInteractionForm(
      channelId: 'c1',
      interactionId: 'i1',
      id: 'p2',
      fields: {'what': 'tea'},
    );
    expect(sent['POST /channels/c1/messages/m1/interactions'], {
      'id': 'p1',
      'custom_id': 'day',
      'values': ['mon', 'tue'],
    });
    expect(sent['POST /channels/c1/interactions/i1/submit'], {
      'id': 'p2',
      'fields': {'what': 'tea'},
    });
  });
}
