// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What Enter does in the palette: it opens the highlighted row, and a last
/// "See all results" row, or Shift+Enter, lists every message hit instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import '../../command_palette_harness.dart';
import '../../support/async_wait.dart';
import 'package:slimm_app/src/features/palette/widgets/command_palette.dart'
    show paletteSearchDebounce;

const _input = Key('command-palette-input');
const _seeAll = 'See all results for "ren"';

Map<String, dynamic> _hit(String id, String content) => {
  'id': id,
  'channel_id': 'ch1',
  'author_id': 'other',
  'author_display_name': 'Ren',
  'seq': 1,
  'content': content,
  'created_at': 0,
  'edited_at': null,
};

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester, {
  Size size = const Size(1400, 900),
  List<Map<String, dynamic>> hits = const [],
}) async {
  final setup = setupPalette(hits: hits);
  await MessageStore(setup.db).upsertChannels(const [
    api.Channel(id: 'ch1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pump(tester, setup.container, size: size);
  await pressCtrlK(tester);
  return setup;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(_input), text);
  await tester.pump(paletteSearchDebounce);
  await pumpFrames(tester);
}

String _path(WidgetTester tester) =>
    GoRouterState.of(tester.element(find.text('conversation').first)).uri.path;

void main() {
  testWidgets('Enter on a typed name opens that person, not the results', (
    tester,
  ) async {
    final setup = await _open(tester, hits: [_hit('m1', 'ren said hi')]);
    await _type(tester, 'ren');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester, frames: 30);

    expect(find.byKey(_input), findsNothing);
    expect(_path(tester), '/channels/dm-1');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Enter on free text with no name match opens the first hit', (
    tester,
  ) async {
    final setup = await _open(tester, hits: [_hit('m1', 'zebra crossing')]);
    await _type(tester, 'zebra');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester, frames: 30);

    expect(find.byKey(_input), findsNothing);
    expect(_path(tester), '/channels/ch1');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Enter straight after typing still opens the first hit', (
    tester,
  ) async {
    final setup = await _open(tester, hits: [_hit('m1', 'zebra crossing')]);
    await tester.enterText(find.byKey(_input), 'zebra');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester, frames: 30);

    expect(find.byKey(_input), findsNothing);
    expect(_path(tester), '/channels/ch1');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('the last row opens every message hit and drops other sections', (
    tester,
  ) async {
    final setup = await _open(tester, hits: [_hit('m1', 'ren said hi')]);
    await _type(tester, 'ren');
    expect(inPalette('PEOPLE'), findsOneWidget);
    await tester.ensureVisible(inPalette(_seeAll));
    await tester.tap(inPalette(_seeAll));
    await pumpFrames(tester);

    expect(find.byKey(_input), findsOneWidget);
    expect(inPalette('PEOPLE'), findsNothing);
    expect(inPalette(_seeAll), findsNothing);
    expect(inPalette('MESSAGES'), findsOneWidget);
    expect(_path(tester), '/channels', reason: 'nothing was opened yet');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('Shift+Enter opens the full results without opening a row', (
    tester,
  ) async {
    final setup = await _open(tester, hits: [_hit('m1', 'ren said hi')]);
    await _type(tester, 'ren');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await pumpFrames(tester);

    expect(find.byKey(_input), findsOneWidget);
    expect(inPalette('PEOPLE'), findsNothing);
    expect(inPalette('MESSAGES'), findsOneWidget);
    expect(_path(tester), '/channels');

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('arrowing to the last row and pressing Enter shows all results', (
    tester,
  ) async {
    final setup = await _open(tester, hits: [_hit('m1', 'ren said hi')]);
    await _type(tester, 'ren');
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    }
    await pumpFrames(tester);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester);

    expect(find.byKey(_input), findsOneWidget);
    expect(inPalette('PEOPLE'), findsNothing);
    expect(inPalette('MESSAGES'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('editing the text leaves the full results', (tester) async {
    final setup = await _open(tester, hits: [_hit('m1', 'ren said hi')]);
    await _type(tester, 'ren');
    await tester.tap(inPalette(_seeAll));
    await pumpFrames(tester);
    await _type(tester, 'rens');

    expect(inPalette('PEOPLE'), findsNothing, reason: 'no one is named rens');
    expect(inPalette('See all results for "rens"'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });

  testWidgets('a phone lists the row under the people and taps it', (
    tester,
  ) async {
    final setup = await _open(
      tester,
      size: const Size(390, 844),
      hits: [_hit('m1', 'ren said hi')],
    );
    await _type(tester, 'ren');

    final row = inCompactPalette(_seeAll);
    expect(row, findsOneWidget);
    expect(
      tester.getTopLeft(row).dy,
      greaterThan(tester.getTopLeft(inCompactPalette('PEOPLE')).dy),
    );
    expect(tester.getRect(row).right, lessThanOrEqualTo(390));
    await tester.tap(row);
    await pumpFrames(tester);

    expect(inCompactPalette('PEOPLE'), findsNothing);
    expect(inCompactPalette('MESSAGES'), findsOneWidget);

    await teardown(tester, setup.container, setup.db);
  });
}
