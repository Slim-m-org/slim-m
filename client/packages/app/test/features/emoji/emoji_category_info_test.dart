// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each emoji category is a tab in the picker with a label and an icon, and no
/// two may share either: a repeated label or icon makes two tabs read as the
/// same one, so a copy-paste that duplicates one is caught here rather than in
/// a confused picker.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';

void main() {
  test(
    'every category has a non-empty label, and labels and icons are distinct',
    () {
      final labels = <String>{};
      final icons = <IconData>{};
      for (final category in EmojiCategory.values) {
        expect(category.label, isNotEmpty, reason: '$category has no label');
        expect(
          labels.add(category.label),
          isTrue,
          reason: 'two categories share the label "${category.label}"',
        );
        expect(
          icons.add(category.icon),
          isTrue,
          reason: 'two categories share an icon ($category)',
        );
      }
    },
  );
}
