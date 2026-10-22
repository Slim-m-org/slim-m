// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [loadRealFonts] used to guard the Lucide lookup with `existsSync()` and
/// silently skip it when the file could not be found, so a wrong pub cache
/// path meant the icon font never loaded and nothing in the run said so: the
/// CI overflow gate would measure a layout with every glyph an empty square
/// as though it were the real thing that ships.
library;

import 'package:flutter_test/flutter_test.dart';

import 'ui_snapshot_support.dart';

void main() {
  test('a Lucide font that cannot be found fails the fixture, rather than '
      'silently leaving every icon unloaded', () {
    expect(
      () => loadRealFonts(pubCacheOverride: '/definitely/not/a/pub/cache'),
      throwsA(anything),
    );
  });

  test(
    'a colour emoji face that cannot be found does not fail the whole render, '
    'since it is a system font and not ours to ship',
    () {
      expect(
        loadEmojiFont(pathsOverride: const ['/definitely/not/an/emoji/font']),
        completes,
      );
    },
  );

  test('the machine writing snapshots has a colour emoji face, so a reaction '
      'in a captured render is the real glyph rather than a tofu box', () {
    expect(
      emojiFontPath(),
      isNotNull,
      reason:
          'without one, every emoji in every captured screenshot is a box, '
          'and emoji here are user content rather than chrome',
    );
  }, skip: writingSnapshots ? false : 'only a capture run needs real pixels');
}
