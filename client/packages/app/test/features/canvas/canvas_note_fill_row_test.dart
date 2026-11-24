// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The note fill row offers the default amber once, not again as a pen colour.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_custom_colours.dart';

void main() {
  test('a swatch row can leave a pen colour out', () {
    final all = canvasPenColourSwatches(selectedKey: '', onChoose: (_) {});
    final fill = canvasPenColourSwatches(
      selectedKey: '',
      onChoose: (_) {},
      without: const {'amber'},
    );
    expect(all.map((s) => s.label), contains('Amber'));
    expect(fill.map((s) => s.label), isNot(contains('Amber')));
    expect(fill.length, all.length - 1);
  });
}
