// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's travelling selection marker: one list-owned bar that slides
/// from the old row to the new one, jumps under reduce motion, and retracts
/// when its row unmounts or nothing is selected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_selection_marker.dart';
import 'package:slimm_design_system/design_system.dart';

class _Rows extends StatefulWidget {
  const _Rows({required this.initial, super.key});

  final int? initial;

  @override
  State<_Rows> createState() => _RowsState();
}

class _RowsState extends State<_Rows> {
  late int? selected = widget.initial;
  int rows = 3;

  void select(int? index) => setState(() => selected = index);

  void shrinkTo(int count) => setState(() => rows = count);

  @override
  Widget build(BuildContext context) => SelectionMarkerLayer(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows; i++)
          SelectionMarkerTarget(
            selected: i == selected,
            child: SizedBox(height: 40, child: Text('row-$i')),
          ),
      ],
    ),
  );
}

final _rowsKey = GlobalKey<_RowsState>();

Future<void> _pump(
  WidgetTester tester, {
  int? initial,
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: _Rows(key: _rowsKey, initial: initial),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _barTop(WidgetTester tester) => tester
    .getTopLeft(
      find.descendant(
        of: find.byType(SelectionMarkerLayer),
        matching: find.byType(IgnorePointer),
      ),
    )
    .dy;

Finder get _bar => find.descendant(
  of: find.byType(SelectionMarkerLayer),
  matching: find.byType(IgnorePointer),
);

void main() {
  testWidgets('the bar sits on the selected row', (tester) async {
    await _pump(tester, initial: 0);
    expect(_bar, findsOneWidget);
    final row = tester.getTopLeft(find.text('row-0')).dy;
    // Inset 6 from the row's own top; see the layer's build.
    expect(_barTop(tester), closeTo(row + 6, 0.01));
  });

  testWidgets('selection travels: mid-flight the bar is between rows', (
    tester,
  ) async {
    await _pump(tester, initial: 0);
    final from = _barTop(tester);

    _rowsKey.currentState!.select(2);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final mid = _barTop(tester);
    final to = tester.getTopLeft(find.text('row-2')).dy + 6;
    expect(mid, greaterThan(from));
    expect(mid, lessThan(to));

    await tester.pumpAndSettle();
    expect(_barTop(tester), closeTo(to, 0.01));
  });

  testWidgets('reduce motion jumps the bar with no travel', (tester) async {
    await _pump(tester, initial: 0, reduceMotion: true);

    _rowsKey.currentState!.select(2);
    await tester.pump();
    await tester.pump();
    final to = tester.getTopLeft(find.text('row-2')).dy + 6;
    expect(_barTop(tester), closeTo(to, 0.01));
  });

  testWidgets('clearing the selection retracts the bar', (tester) async {
    await _pump(tester, initial: 1);
    expect(_bar, findsOneWidget);

    _rowsKey.currentState!.select(null);
    await tester.pumpAndSettle();
    expect(_bar, findsNothing);
  });

  testWidgets('the selected row unmounting retracts the bar', (tester) async {
    await _pump(tester, initial: 2);
    expect(_bar, findsOneWidget);

    _rowsKey.currentState!.shrinkTo(2);
    await tester.pumpAndSettle();
    expect(_bar, findsNothing);
  });
}
