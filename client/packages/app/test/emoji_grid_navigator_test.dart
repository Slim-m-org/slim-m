// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/emoji_grid_navigator.dart';

void main() {
  group('layout', () {
    test('counts columns the way the grid delegate does', () {
      final nav = EmojiGridNavigator();
      addTearDown(nav.dispose);

      // 320 wide, 16 of padding: 304 across, cells of at most 44 plus a 4 gap.
      nav.layout(320, 44);
      expect(nav.columns, 7);
      nav.layout(120, 44);
      expect(nav.columns, 3);
    });

    test('never reports fewer than one column', () {
      final nav = EmojiGridNavigator();
      addTearDown(nav.dispose);

      nav.layout(0, 44);
      expect(nav.columns, 1);
    });
  });

  group('step', () {
    late EmojiGridNavigator nav;

    setUp(() {
      nav = EmojiGridNavigator()..layout(320, 44);
    });
    tearDown(() => nav.dispose());

    test('moves a whole row, not a cell', () {
      expect(nav.step(3, 100, 1), 3 + nav.columns);
      expect(nav.step(30, 100, -1), 30 - nav.columns);
    });

    test('enters from no highlight at the first cell down, the last up', () {
      expect(nav.step(-1, 100, 1), 0);
      expect(nav.step(-1, 100, -1), 99);
    });

    test('stays on the first row going up', () {
      expect(nav.step(2, 100, -1), 2);
    });

    test('lands on the last cell when the next row is short', () {
      // 100 cells at 7 a row: the last row holds 2 cells, indices 98 and 99.
      expect(nav.step(95, 100, 1), 99);
    });

    test('stays on the last row going down', () {
      expect(nav.step(98, 100, 1), 98);
    });

    test('has no highlight when there is nothing to highlight', () {
      expect(nav.step(-1, 0, 1), -1);
      expect(nav.step(4, 0, -1), -1);
    });
  });
}
