// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [SettingsSelectRow] with many choices (every channel) opens a bounded,
/// searchable list instead of one row per choice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

const _rowKey = ValueKey('channels-row');

Widget _harness(int count, void Function(String) onChanged) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: Center(
      child: SettingsSelectRow<String>(
        key: _rowKey,
        label: 'Post level-ups in',
        value: 'c0',
        choices: [
          for (var i = 0; i < count; i++)
            SettingsChoice(value: 'c$i', label: '#channel-$i'),
        ],
        onChanged: onChanged,
      ),
    ),
  ),
);

Future<void> _open(
  WidgetTester tester,
  Size size,
  int count,
  void Function(String) onChanged,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(count, onChanged));
  await tester.tap(find.byKey(_rowKey));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  for (final (name, size) in [
    ('desktop', const Size(1000, 800)),
    ('phone', const Size(400, 800)),
  ]) {
    testWidgets('$name: 25 choices stay bounded and searchable', (
      tester,
    ) async {
      String? picked;
      await _open(tester, size, 25, (v) => picked = v);

      final list = find.byKey(const ValueKey('choice-list'));
      expect(list, findsOneWidget);
      expect(tester.getSize(list).height, lessThanOrEqualTo(280));
      expect(find.text('#channel-24'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('choice-search')), '24');
      await tester.pump();
      expect(find.text('#channel-24'), findsOneWidget);
      expect(find.text('#channel-3'), findsNothing);

      await tester.tap(find.text('#channel-24'));
      await tester.pump(const Duration(seconds: 1));
      expect(picked, 'c24');
    });

    testWidgets('$name: a short list keeps no search field', (tester) async {
      await _open(tester, size, 5, (_) {});
      expect(find.byKey(const ValueKey('choice-search')), findsNothing);
      expect(find.text('#channel-4'), findsOneWidget);
    });
  }
}
