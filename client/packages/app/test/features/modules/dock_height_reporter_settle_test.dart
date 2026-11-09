// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock card tweens its own size for 180 ms when a row comes or goes, and a
/// screen that lays its stage out around the dock's height must hear the final
/// height once, not every frame of the tween.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/dock_height_reporter.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';

const _row = SizedBox(width: 120, height: 40);
const _cardKey = ValueKey('dock-card');

class _Heard {
  final heights = <double>[];
  final widths = <double>[];
}

Future<ValueNotifier<int>> _pumpDock(
  WidgetTester tester,
  _Heard heard, {
  bool local = true,
  ProviderContainer? container,
}) async {
  final rows = ValueNotifier<int>(1);
  addTearDown(rows.dispose);
  final dock = ValueListenableBuilder<int>(
    valueListenable: rows,
    builder: (context, count, _) => DockHeightReporter(
      onHeight: local ? heard.heights.add : null,
      onWidth: local ? heard.widths.add : null,
      child: FloatingDockCard(
        key: _cardKey,
        rows: [for (var i = 0; i < count; i++) _row],
      ),
    ),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container ?? ProviderContainer(),
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: dock),
        ),
      ),
    ),
  );
  await tester.pump();
  return rows;
}

Future<void> _frames(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('the first measurement is heard at once', (tester) async {
    final heard = _Heard();
    await _pumpDock(tester, heard);

    expect(heard.heights, hasLength(1));
    expect(heard.widths, hasLength(1));
  });

  testWidgets('a row coming is heard once, after the card has grown', (
    tester,
  ) async {
    final heard = _Heard();
    final rows = await _pumpDock(tester, heard);
    final before = heard.heights.single;

    rows.value = 2;
    await _frames(tester, 3);
    expect(heard.heights, [before], reason: 'still tweening');
    await _frames(tester, 20);

    expect(heard.heights, hasLength(2));
    expect(heard.heights.last, greaterThan(before));
    final settled = tester.getSize(find.byKey(_cardKey)).height;
    expect(heard.heights.last, settled);
  });

  testWidgets('a row going is heard once as well', (tester) async {
    final heard = _Heard();
    final rows = await _pumpDock(tester, heard);
    rows.value = 3;
    await _frames(tester, 30);
    final tall = heard.heights.last;

    rows.value = 1;
    await _frames(tester, 30);

    expect(heard.heights, hasLength(3));
    expect(heard.heights.last, lessThan(tall));
  });

  testWidgets('the shared reservation still follows the tween', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final seen = <double>[];
    container.listen(
      bottomDockReservationProvider,
      (_, next) => seen.add(next),
    );
    final rows = await _pumpDock(
      tester,
      _Heard(),
      local: false,
      container: container,
    );

    rows.value = 2;
    await _frames(tester, 20);

    expect(seen.length, greaterThan(3));
  });
}
