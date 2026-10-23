// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The form a module's declared settings generate: every type edits, Save
/// sends only what changed, and a stored secret is never shown.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/admin/module_settings_form.dart';
import 'package:slimm_design_system/design_system.dart';

api.ModuleSettingsDoc _doc({bool secretSet = true}) =>
    api.ModuleSettingsDoc.fromJson({
      'settings': [
        {'key': 'loud', 'type': 'bool', 'label': 'Loud mode', 'value': false},
        {
          'key': 'mode',
          'type': 'choice',
          'label': 'Mode',
          'help': 'How it answers.',
          'value': 'calm',
          'choices': [
            {'value': 'calm', 'label': 'Calm'},
            {'value': 'wild', 'label': 'Wild'},
          ],
        },
        {
          'key': 'limit',
          'type': 'int',
          'label': 'Daily limit',
          'min': 1,
          'max': 10,
          'value': 5,
        },
        {'key': 'cap', 'type': 'int', 'label': 'Cap', 'min': 0, 'value': 100},
        {
          'key': 'name',
          'type': 'string',
          'label': 'Display name',
          'value': 'x',
        },
        {
          'key': 'token',
          'type': 'secret',
          'label': 'API token',
          'value': {'set': secretSet},
        },
        {'key': 'odd', 'type': 'hologram', 'label': 'Odd one'},
      ],
    });

Future<List<Map<String, Object?>>> _pump(
  WidgetTester tester, {
  api.ModuleSettingsDoc? doc,
  String? error,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final saved = <Map<String, Object?>>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ModuleSettingsForm(
            doc: doc ?? _doc(),
            error: error,
            onSave: (values) async => saved.add(values),
          ),
        ),
      ),
    ),
  );
  return saved;
}

Finder _input(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label),
  matching: find.byType(EditableText),
);

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Save changes'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every type renders with the schema label and help', (
    tester,
  ) async {
    await _pump(tester);
    for (final label in [
      'Loud mode',
      'Mode',
      'Daily limit',
      'Cap',
      'Display name',
      'API token',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text('How it answers.'), findsOneWidget);
    expect(find.byType(AppToggle), findsOneWidget);
    expect(find.byType(AppSlider), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('an unknown type is a muted line and does not crash', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.textContaining('Odd one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save sends only the values that changed', (tester) async {
    final saved = await _pump(tester);
    await tester.tap(find.byType(AppToggle));
    await tester.enterText(_input('Display name'), 'Bob');
    await tester.enterText(_input('Cap'), '250');
    await tester.pump();
    expect(find.text('3 unsaved changes'), findsOneWidget);
    await _save(tester);
    expect(saved.single, {'loud': true, 'name': 'Bob', 'cap': 250});
  });

  testWidgets('choosing another choice and moving the slider are changes', (
    tester,
  ) async {
    final saved = await _pump(tester);
    await tester.tap(find.text('Calm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wild').last);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(AppSlider), const Offset(-200, 0));
    await tester.pump();
    await _save(tester);
    final sent = saved.single;
    expect(sent['mode'], 'wild');
    expect(sent['limit'], isA<int>().having((v) => v, 'below 5', lessThan(5)));
    expect(sent.keys, unorderedEquals(['mode', 'limit']));
  });

  testWidgets('a stored secret is never shown, only that it is set', (
    tester,
  ) async {
    await _pump(
      tester,
      doc: api.ModuleSettingsDoc.fromJson({
        'settings': [
          {
            'key': 'token',
            'type': 'secret',
            'label': 'API token',
            'value': {'set': true, 'secret': 'hunter2'},
          },
        ],
      }),
    );
    expect(find.text('Set'), findsOneWidget);
    expect(find.textContaining('hunter2'), findsNothing);
    final field = tester.widget<EditableText>(_input('API token'));
    expect(field.obscureText, isTrue);
    expect(field.controller.text, isEmpty);
  });

  testWidgets('an untouched secret is not sent', (tester) async {
    final saved = await _pump(tester);
    await tester.enterText(_input('Display name'), 'Bob');
    await tester.pump();
    await _save(tester);
    expect(saved.single.containsKey('token'), isFalse);
  });

  testWidgets('typing a secret sends it and clearing sends null', (
    tester,
  ) async {
    final saved = await _pump(tester);
    await tester.enterText(_input('API token'), 's3cret');
    await tester.pump();
    await _save(tester);
    expect(saved.last, {'token': 's3cret'});

    await tester.enterText(_input('API token'), '');
    await tester.pump();
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('Will be cleared'), findsOneWidget);
    await _save(tester);
    expect(saved.last, {'token': null});
  });

  testWidgets('clearing a secret that was never set offers nothing', (
    tester,
  ) async {
    await _pump(tester, doc: _doc(secretSet: false));
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('an unbounded number must be whole and within its range', (
    tester,
  ) async {
    final saved = await _pump(tester);
    await tester.enterText(_input('Cap'), '-');
    await tester.pump();
    await _save(tester);
    expect(find.text('Cap needs a whole number.'), findsOneWidget);
    await tester.enterText(_input('Cap'), '-4');
    await tester.pump();
    await _save(tester);
    expect(find.text('Cap must be at least 0.'), findsOneWidget);
    expect(saved, isEmpty);
  });

  testWidgets('Discard puts every edit back', (tester) async {
    await _pump(tester);
    await tester.enterText(_input('Display name'), 'Bob');
    await tester.pump();
    await tester.tap(find.text('Discard'));
    await tester.pump();
    expect(find.text('Save changes'), findsNothing);
    expect(
      tester.widget<EditableText>(_input('Display name')).controller.text,
      'x',
    );
  });

  testWidgets('a failed save shows the error and keeps the edits', (
    tester,
  ) async {
    await _pump(tester, error: 'Could not save the settings');
    expect(find.text('Could not save the settings'), findsOneWidget);
    await tester.enterText(_input('Display name'), 'Bob');
    await tester.pump();
    expect(find.text('Could not save the settings'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
  });
}
