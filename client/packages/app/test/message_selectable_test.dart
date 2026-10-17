// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message row while the transcript is selecting, driven through the real
/// widget rather than through the state behind it.
///
/// `message_selection_test.dart` already proves what the set does. What only
/// a pumped tree can answer is the part that makes selection safe to ship:
/// that a row is left completely alone while the mode is off, and that once
/// it is on, the row's own interactions can no longer fire. A half-live row -
/// one where a tap selects but a link inside it still navigates - is the
/// usual way this pattern goes wrong, and it is invisible to a state test.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/message_selection.dart';
import 'package:slimm_app/src/features/messages/widgets/message_selectable.dart';
import 'package:slimm_design_system/design_system.dart';

const _channel = 'c1';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required VoidCallback onRowTapped,
  List<String> ids = const ['m1', 'm2'],
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Column(
            children: [
              for (final id in ids)
                MessageSelectable(
                  channelId: _channel,
                  messageId: id,
                  order: ids,
                  child: GestureDetector(
                    onTap: onRowTapped,
                    child: SizedBox(height: 40, width: 200, child: Text(id)),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('the row keeps its own tap while the mode is off', (
    tester,
  ) async {
    var rowTaps = 0;
    final container = await _pump(tester, onRowTapped: () => rowTaps++);

    await tester.tap(find.text('m1'));
    await tester.pumpAndSettle();

    expect(rowTaps, 1, reason: 'an ordinary transcript is untouched by this');
    expect(
      container.read(messageSelectionProvider(_channel)).count,
      0,
      reason: 'and a plain tap must not begin selecting anything',
    );
  });

  testWidgets('while selecting, a tap picks the row instead of firing it', (
    tester,
  ) async {
    var rowTaps = 0;
    final container = await _pump(tester, onRowTapped: () => rowTaps++);
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('m2'));
    await tester.pumpAndSettle();

    expect(container.read(messageSelectionProvider(_channel)).count, 2);
    expect(
      rowTaps,
      0,
      reason:
          'the row underneath must be inert, or a link inside a message '
          'would navigate away mid-selection',
    );
  });

  testWidgets('tapping a picked row lets it go again', (tester) async {
    final container = await _pump(tester, onRowTapped: () {});
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('m1'));
    await tester.pumpAndSettle();

    expect(
      container.read(messageSelectionProvider(_channel)).contains('m1'),
      isFalse,
    );
  });

  testWidgets('a selected row is announced as selected', (tester) async {
    final handle = tester.ensureSemantics();
    final container = await _pump(tester, onRowTapped: () {});
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('Selected, tap to deselect'),
      findsOneWidget,
      reason: 'the tick is a colour and a shape, so it has to be spoken too',
    );
    expect(find.bySemanticsLabel('Tap to select'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('no selection chrome is added while the mode is off', (
    tester,
  ) async {
    await _pump(tester, onRowTapped: () {});
    // Scoped to the wrapper: a Scaffold has IgnorePointers of its own.
    expect(
      find.descendant(
        of: find.byType(MessageSelectable),
        matching: find.byType(IgnorePointer),
      ),
      findsNothing,
      reason:
          'the wrapper returns its child untouched, so a normal transcript '
          'carries none of this',
    );
  });

  testWidgets('a shift-tap picks every row between the last plain tap and it', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      onRowTapped: () {},
      ids: const ['m1', 'm2', 'm3', 'm4'],
    );
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('m4'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(
      container.read(messageSelectionProvider(_channel)).ids,
      {'m1', 'm2', 'm3', 'm4'},
      reason: 'm2 and m3 were never tapped; the held shift is what picked them',
    );
  });

  testWidgets('the same tap without shift picks only the row it landed on', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      onRowTapped: () {},
      ids: const ['m1', 'm2', 'm3', 'm4'],
    );
    container.read(messageSelectionProvider(_channel).notifier).start('m1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('m4'));
    await tester.pumpAndSettle();

    expect(container.read(messageSelectionProvider(_channel)).ids, {
      'm1',
      'm4',
    });
  });
}
