// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of what a bot puts in front of a member: the form a button
/// press opens and the select menus on its message. Both open over the real
/// transcript, so both widths and both themes are captured. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a clean
/// layout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/bot_forms.dart';
import 'package:slimm_app/src/features/messages/widgets/bot_form_sheet.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_support.dart';

const _bot = 'user-bot';
const _nick = 'user-nick';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

// Forms.

const _form = api.BotForm(
  customId: 'remind',
  title: 'Remind me',
  submitLabel: 'Set reminder',
  fields: [
    api.BotFormField(
      customId: 'what',
      label: 'What',
      placeholder: 'Water the plants',
      maxLength: 80,
    ),
    api.BotFormField(
      customId: 'note',
      label: 'Note',
      required: false,
      multiline: true,
      value: 'weekly',
    ),
  ],
);

const _request = BotFormRequest(
  interactionId: 'i-1',
  channelId: 'c-general',
  botId: _bot,
  form: _form,
);

List<api.Message> _botMessage(List<api.ComponentRow> rows) => [
  reviewMessage(1, _nick, '!remind'),
  reviewMessage(
    2,
    _bot,
    'Pick what to be reminded about, or press Remind me for a custom one.',
    components: rows,
  ),
];

const _pressForm = [
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: 'Remind me',
        style: api.ComponentButtonStyle.primary,
        customId: 'remind',
      ),
    ],
  ),
];

Finder get _fields => find.byWidgetPredicate((w) => w is EditableText);

/// The form's two fields are the last two inputs, after the composer's.
Future<void> _fillForm(ReviewScene scene) async {
  unawaited(showBotFormSheet(scene.context, _request));
  await scene.frames(3);
  final count = _fields.evaluate().length;
  await scene.tester.enterText(
    _fields.at(count - 2),
    'Stand-up notes for Friday',
  );
  await scene.frames(2);
}

Future<void> _submit(ReviewScene scene) async {
  await _fillForm(scene);
  await scene.tester.tap(find.text('Set reminder'));
  await scene.frames(3);
}

Future<void> _submitAndWait(ReviewScene scene) async {
  await _submit(scene);
  await scene.tester.pump(botFormTimeout + const Duration(seconds: 1));
  await scene.frames(2);
}

http.Response? _refuseForm(http.Request request) => request.method == 'POST'
    ? _json({'error': 'the reminder time must be in the future'}, 400)
    : null;

http.Response? _acceptForm(http.Request request) =>
    request.method == 'POST' ? _json({'id': 'sub-1', 'created_at': 1}) : null;

// Selects.

api.ComponentRow _select({
  required String placeholder,
  required int options,
  int minValues = 1,
  int maxValues = 1,
  bool described = false,
}) => api.ComponentRow(
  select: api.MessageSelect(
    customId: 'day',
    placeholder: placeholder,
    minValues: minValues,
    maxValues: maxValues,
    options: [
      for (var i = 0; i < options; i++)
        api.SelectChoice(
          label: _days[i % _days.length],
          value: 'd$i',
          description: described ? 'Room ${100 + i} is free after lunch' : null,
        ),
    ],
  ),
);

const _days = [
  'Monday morning',
  'Monday afternoon',
  'Tuesday morning',
  'Tuesday afternoon',
  'Wednesday morning',
  'Wednesday afternoon',
  'Thursday morning',
  'Thursday afternoon',
  'Friday morning',
  'Friday afternoon',
  'Saturday morning',
  'Sunday evening',
];

Future<void> _openSelect(ReviewScene scene, String placeholder) async {
  await scene.tester.tap(find.text(placeholder));
  await scene.frames(3);
}

Future<void> _pickTwo(ReviewScene scene) async {
  await _openSelect(scene, 'Pick two days');
  await scene.tester.tap(find.text('Tuesday morning'));
  await scene.frames(1);
  await scene.tester.tap(find.text('Wednesday afternoon'));
  await scene.frames(2);
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    testWidgets('form fields at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'sheet-bot-form',
        state: 'fields',
        viewport: viewport,
        messages: _botMessage(_pressForm),
        act: _fillForm,
      );
    });

    testWidgets('form validation error at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'sheet-bot-form',
        state: 'validation-error',
        viewport: viewport,
        messages: _botMessage(_pressForm),
        serve: _refuseForm,
        act: _submit,
      );
    });

    testWidgets('form no answer at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'sheet-bot-form',
        state: 'no-answer',
        viewport: viewport,
        messages: _botMessage(_pressForm),
        serve: _acceptForm,
        act: _submitAndWait,
      );
    });

    testWidgets('select long list at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'sheet-bot-select',
        state: 'long-list',
        viewport: viewport,
        messages: _botMessage([
          _select(placeholder: 'Pick a day', options: 12, described: true),
        ]),
        act: (scene) => _openSelect(scene, 'Pick a day'),
      );
    });

    testWidgets('select multiple at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'sheet-bot-select',
        state: 'multi-select',
        viewport: viewport,
        messages: _botMessage([
          _select(
            placeholder: 'Pick two days',
            options: 6,
            minValues: 2,
            maxValues: 3,
          ),
        ]),
        act: _pickTwo,
      );
    });

    testWidgets('select short menu at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: 'sheet-bot-select',
        state: 'short-menu',
        viewport: viewport,
        messages: _botMessage([_select(placeholder: 'Pick a day', options: 4)]),
        act: (scene) => _openSelect(scene, 'Pick a day'),
      );
    });
  }
}
