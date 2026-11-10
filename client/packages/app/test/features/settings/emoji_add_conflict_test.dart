// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A name another admin took while the dialog was open: the server's refusal
/// lands on its own row, the catalog refreshes, the other rows stay creatable,
/// and the names are not checked against a catalog that has not loaded.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../support/geometry.dart';
import 'emoji_add_harness.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _field(String fileName) => find.byKey(ValueKey('emoji-name-$fileName'));

bool _disabled(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).disabled;

const _zorg = api.CustomEmoji(
  id: 'e-zorg',
  name: 'zorg',
  uploaderId: 'other',
  createdAt: 0,
);

http.Response _taken(String name, int index) => emojiJson({
  'error': 'image ${index + 1} ($name): an emoji with that name already exists',
  'item_index': index,
  'item_code': 'name_taken',
}, status: 409);

void main() {
  testWidgets('a name taken meanwhile is flagged on its own row and the rest '
      'stay creatable', (tester) async {
    var calls = 0;
    final h = EmojiHarness(
      picks: [
        emojiPick('aaa.png'),
        emojiPick('zorg.png'),
        emojiPick('ccc.png'),
      ],
      onBulk: (r) {
        if (++calls == 1) return _taken('zorg', 1);
        return emojiJson([
          for (final n in bulkNames(r)) emojiRow(n),
        ], status: 201);
      },
    );
    await h.pump(tester);
    await h.choose(tester);

    await tester.tap(find.text('Create 3 emoji'));
    await _settle(tester);

    final problem = tester.getRect(find.text('Already taken.'));
    expect(
      problem.center.dy,
      greaterThan(tester.getRect(_field('zorg.png')).center.dy),
      reason: 'the problem sits under the row the server named',
    );
    expect(
      problem.center.dy,
      lessThan(tester.getRect(_field('ccc.png')).top),
      reason: 'and above the next row, not under another one',
    );
    expect(find.text('1 name needs fixing.'), findsOneWidget);
    expect(
      find.textContaining('could not be added'),
      findsNothing,
      reason: 'the row already says it, so the summary does not repeat it',
    );
    expect(_disabled(tester, 'Create 3 emoji'), isTrue);
    expect(_field('aaa.png'), findsOneWidget);
    expect(_field('ccc.png'), findsOneWidget);

    await tester.enterText(_field('zorg.png'), 'zorg_two');
    await _settle(tester);
    expect(find.text('Already taken.'), findsNothing);
    expect(_disabled(tester, 'Create 3 emoji'), isFalse);

    await tester.tap(find.text('Create 3 emoji'));
    await _settle(tester);
    expect(bulkNames(h.bulks.last), ['aaa', 'zorg_two', 'ccc']);
    expect(find.textContaining('Added 3 of 3'), findsOneWidget);
  });

  testWidgets('the list is refreshed when every chunk failed, so a taken name '
      'shows on its row', (tester) async {
    final h = EmojiHarness(
      picks: [emojiPick('aaa.png'), emojiPick('zorg.png')],
      onBulk: (r) => emojiJson({
        'error': 'an emoji with that name already exists',
      }, status: 409),
    );
    await h.pump(tester);
    await h.choose(tester);
    expect(h.listFetches, 1);

    h.added.add(_zorg);
    await tester.tap(find.text('Create 2 emoji'));
    await _settle(tester);

    expect(h.listFetches, 2, reason: 'a failed attempt still refreshes');
    expect(find.text('Already taken.'), findsOneWidget);
    expect(_disabled(tester, 'Create 2 emoji'), isTrue);
  });

  testWidgets('a single image refused for a taken name is flagged after the '
      'list refreshes', (tester) async {
    final h = EmojiHarness(
      picks: [emojiPick('zorg.png')],
      onSingle: (r) => emojiJson({
        'error': 'an emoji with that name already exists',
      }, status: 409),
    );
    await h.pump(tester);
    await h.choose(tester);

    h.added.add(_zorg);
    await tester.tap(find.text('Create 1 emoji'));
    await _settle(tester);

    expect(find.text('Already taken.'), findsOneWidget);
    expect(_field('zorg.png'), findsOneWidget);
  });

  testWidgets('names wait for the catalog instead of passing against an '
      'empty one', (tester) async {
    final gate = Completer<void>();
    final h = EmojiHarness(
      existing: const [_zorg],
      picks: [emojiPick('zorg.png')],
      onSingle: (r) => emojiJson(emojiRow('zorg'), status: 201),
    );
    h.catalogGate = gate.future;
    await h.pump(tester);
    await h.choose(tester);

    expect(find.text('Checking existing names...'), findsOneWidget);
    expect(_disabled(tester, 'Create 1 emoji'), isTrue);

    gate.complete();
    await _settle(tester);

    expect(find.text('Checking existing names...'), findsNothing);
    expect(find.text('Already taken.'), findsOneWidget);
    expect(_disabled(tester, 'Create 1 emoji'), isTrue);
  });

  testWidgets('a catalog that failed to load does not block creating', (
    tester,
  ) async {
    final gate = Completer<void>();
    final h = EmojiHarness(
      picks: [emojiPick('fine.png')],
      onSingle: (r) => emojiJson(emojiRow('fine'), status: 201),
    );
    h.catalogGate = gate.future;
    await h.pump(tester);
    await h.choose(tester);
    gate.completeError(StateError('offline'));
    await _settle(tester);

    expect(find.text('Checking existing names...'), findsNothing);
    expect(_disabled(tester, 'Create 1 emoji'), isFalse);
  });

  testWidgets('Show first scrolls a flagged row out of sight into view', (
    tester,
  ) async {
    final h = EmojiHarness(
      existing: const [_zorg],
      picks: [
        for (var i = 0; i < 40; i++)
          emojiPick(i == 34 ? 'zorg.png' : 'pic$i.png'),
      ],
      onBulk: (r) => emojiJson(const {}),
    );
    await h.pump(tester);
    await h.choose(tester);

    expect(find.text('1 name needs fixing.'), findsOneWidget);
    expect(
      _field('zorg.png'),
      findsNothing,
      reason: 'built lazily, off screen',
    );

    await tester.tap(find.text('Show first'));
    await _settle(tester);

    expect(find.text('Already taken.'), findsOneWidget);
    final list = find.byKey(const ValueKey('emoji-review-list'));
    for (final row in [find.text('Already taken.'), _field('zorg.png')]) {
      expectClearOfEdge(tester, row, GeometryEdge.top, from: list);
      expectClearOfEdge(tester, row, GeometryEdge.bottom, from: list);
    }
  });
}
