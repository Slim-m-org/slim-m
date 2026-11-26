// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The note and the text box share one short style bar: a colour button that opens a popover, then the size.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_selection_bar.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';
import 'canvas_text_pane_support.dart';

Map<String, dynamic> _note() => {
  ...canvasNoteJson('note', x: 100, authorId: 'me', text: 'hello'),
  'y': 100.0,
  'w': 330.0,
  'h': 210.0,
  'props': {'text': 'hello'},
};

Map<String, dynamic> _text() => {...textBoxJson('box'), 'x': 20.0, 'y': 300.0};

final _bar = find.byWidgetPredicate((w) => w is CanvasSelectionBar);

Future<CanvasPaneFixture> _select(
  WidgetTester tester, {
  required Map<String, dynamic> object,
  required Offset tapAt,
  required double width,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = await openPane(tester, objects: [object]);
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
  await tester.tapAt(screenFor(tester, tapAt), kind: PointerDeviceKind.mouse);
  await pumpFrames(tester);
  return fixture;
}

void main() {
  for (final width in [390.0, 1280.0]) {
    for (final kind in ['note', 'text']) {
      testWidgets('the $kind bar is one short row at $width', (tester) async {
        await _select(
          tester,
          object: kind == 'note' ? _note() : _text(),
          tapAt: kind == 'note'
              ? const Offset(300, 200)
              : const Offset(100, 315),
          width: width,
        );

        final bar = tester.getRect(_bar);
        expect(bar.width, lessThanOrEqualTo(canvasSelectionBarMaxWidth));
        expect(bar.left, greaterThanOrEqualTo(0));
        expect(bar.right, lessThanOrEqualTo(width));
        expect(bar.height, lessThan(64));
        final colour = tester.getRect(
          find.byTooltip(kind == 'note' ? 'Colours' : 'Text colour'),
        );
        final size = tester.getRect(find.bySemanticsLabel('Text size'));
        expect(colour.right, lessThanOrEqualTo(size.left));
        expect(bar.contains(colour.center), isTrue);
        expect(bar.contains(size.center), isTrue);
      });
    }
  }

  testWidgets('the note bar has no emoji button and no inline swatch rows', (
    tester,
  ) async {
    await _select(
      tester,
      object: _note(),
      tapAt: const Offset(300, 200),
      width: 1280,
    );
    expect(find.bySemanticsLabel('Insert emoji'), findsNothing);
    expect(find.bySemanticsLabel('Default fill'), findsNothing);
    expect(find.text('Solid'), findsNothing);
  });

  testWidgets('the colour button opens fill, fill mode and text colour', (
    tester,
  ) async {
    final fixture = await _select(
      tester,
      object: _note(),
      tapAt: const Offset(300, 200),
      width: 1280,
    );
    await tester.tap(find.byTooltip('Colours'));
    await pumpFrames(tester);

    expect(find.bySemanticsLabel('Default fill'), findsOneWidget);
    expect(find.bySemanticsLabel('Custom colour'), findsNWidgets(2));
    expect(find.text('Clear'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await pumpFrames(tester);
    final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
    expect(edits.single['props'], {'fill_opacity': 0});
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('a text box colour pick sends one edit', (tester) async {
    final fixture = await _select(
      tester,
      object: _text(),
      tapAt: const Offset(100, 315),
      width: 1280,
    );
    await tester.tap(find.byTooltip('Text colour'));
    await pumpFrames(tester);
    await tester.tap(find.byTooltip('Coral'));
    await pumpFrames(tester);

    final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
    expect(edits, hasLength(1));
    expect((edits.single['props'] as Map)['color'], 'annotation');
  });
}
