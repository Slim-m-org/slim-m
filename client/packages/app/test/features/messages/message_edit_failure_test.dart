// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refused edit keeps its field open with the typed text and says why under
/// it, and an edit past the message limit is refused before it is sent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_editing.dart';
import 'package:slimm_app/src/features/messages/widgets/message_edit_field.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../channel_history_harness.dart';

class _Edits {
  _Edits(this.answers);

  final List<http.Response Function()> answers;
  final List<http.Request> patches = [];

  /// When set, an edit waits for it before it is answered.
  Completer<void>? gate;

  Future<http.Response?> answer(http.Request request) async {
    if (request.method != 'PATCH') return null;
    patches.add(request);
    await gate?.future;
    final at = patches.length <= answers.length
        ? patches.length - 1
        : answers.length - 1;
    return answers[at]();
  }
}

http.Response _refused() => http.Response(
  jsonEncode({'error': 'nope'}),
  500,
  headers: {'content-type': 'application/json'},
);

http.Response _saved(String content) => http.Response(
  jsonEncode({
    'id': 'm3',
    'channel_id': 'c1',
    'author_id': 'bob',
    'author_display_name': 'bob',
    'seq': 3,
    'content': content,
    'created_at': 180000,
    'edited_at': 240000,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

final _field = find.descendant(
  of: find.bySubtype<MessageEditField>(),
  matching: find.bySubtype<TextField>(),
);

Future<HistoryHarness> _pump(WidgetTester tester, _Edits edits) async {
  final harness = await mountChannel(
    tester,
    serverSeqs: const [1, 2, 3],
    seededSeqs: const [1, 2, 3],
    messageAuthorId: 'bob',
    answerFirst: edits.answer,
  );
  harness.container.read(editingMessageIdProvider('c1').notifier).state = 'm3';
  harness.container.listen(editingMessageIdProvider('c1'), (_, _) {});
  await flush(tester);
  return harness;
}

/// Polls real time for [condition]; a busy button never settles, so nothing here waits on settling.
Future<void> _until(WidgetTester tester, bool Function() condition) async {
  await tester.runAsync(() => pollUntil(condition));
  await flush(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('a refused edit keeps the field, the text and says why', (
    tester,
  ) async {
    final edits = _Edits([_refused]);
    final harness = await _pump(tester, edits);

    await tester.enterText(_field, 'a long rewrite');
    await tester.tap(find.text('Save'));
    await _until(tester, () => edits.patches.isNotEmpty);

    expect(harness.container.read(editingMessageIdProvider('c1')), 'm3');
    expect(find.widgetWithText(TextField, 'a long rewrite'), findsOneWidget);
    expect(find.textContaining('Could not save the edit'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('saving again after a refusal closes the edit once it lands', (
    tester,
  ) async {
    final edits = _Edits([_refused, () => _saved('a long rewrite')]);
    final harness = await _pump(tester, edits);
    await tester.enterText(_field, 'a long rewrite');
    await tester.tap(find.text('Save'));
    await _until(tester, () => edits.patches.length == 1);

    await tester.tap(find.text('Save'));
    await _until(
      tester,
      () => harness.container.read(editingMessageIdProvider('c1')) == null,
    );

    expect(edits.patches, hasLength(2));
    expect(find.bySubtype<MessageEditField>(), findsNothing);
    expect(jsonDecode(edits.patches.last.body)['content'], 'a long rewrite');
    await _unmount(tester);
  });

  testWidgets('the field stays put and read-only while the request is out', (
    tester,
  ) async {
    final edits = _Edits([() => _saved('slow rewrite')])
      ..gate = Completer<void>();
    final harness = await _pump(tester, edits);

    await tester.enterText(_field, 'slow rewrite');
    await tester.tap(find.text('Save'));
    await _until(tester, () => edits.patches.isNotEmpty);

    expect(tester.widget<TextField>(_field).readOnly, isTrue);
    expect(harness.container.read(editingMessageIdProvider('c1')), 'm3');

    edits.gate!.complete();
    await _until(
      tester,
      () => harness.container.read(editingMessageIdProvider('c1')) == null,
    );
    expect(find.bySubtype<MessageEditField>(), findsNothing);
    await _unmount(tester);
  });

  for (final (name, answer) in [
    ('lands', () => _saved('slow rewrite')),
    ('is refused', _refused),
  ]) {
    testWidgets('a save that $name after its field was cancelled and '
        'reopened leaves the new field alone', (tester) async {
      final edits = _Edits([answer])..gate = Completer<void>();
      final harness = await _pump(tester, edits);
      final editing = harness.container.read(
        editingMessageIdProvider('c1').notifier,
      );
      await tester.enterText(_field, 'slow rewrite');
      await tester.tap(find.text('Save'));
      await _until(tester, () => edits.patches.isNotEmpty);

      editing.state = null;
      await flush(tester);
      editing.state = 'm3';
      await flush(tester);
      await tester.enterText(_field, 'second draft');
      edits.gate!.complete();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await flush(tester);

      expect(harness.container.read(editingMessageIdProvider('c1')), 'm3');
      expect(find.widgetWithText(TextField, 'second draft'), findsOneWidget);
      expect(find.textContaining('Could not save the edit'), findsNothing);
      expect(edits.patches, hasLength(1));
      await _unmount(tester);
    });
  }

  testWidgets('an edit past the message limit is not sent', (tester) async {
    final edits = _Edits([() => _saved('x')]);
    final harness = await _pump(tester, edits);
    const over = api.kMessageMaxChars + 1;

    await tester.enterText(_field, 'x' * over);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await flush(tester);

    expect(edits.patches, isEmpty);
    expect(find.text('$over / ${api.kMessageMaxChars}'), findsOneWidget);
    expect(harness.container.read(editingMessageIdProvider('c1')), 'm3');
    await _unmount(tester);
  });
}
