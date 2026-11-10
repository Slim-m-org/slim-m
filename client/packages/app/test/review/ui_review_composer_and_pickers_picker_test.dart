// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's emoji and GIF picker, opened from its smile button: the
/// anchored panel on a desktop window and the bottom sheet on a phone. Emoji,
/// GIF trending, a search with results, no matches and a provider that is
/// down, and the Favorites half of the GIFs tab. Dark and light; the PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1.
///
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

const _surface = 'popover-composer-picker';

/// The phone's Emoji tab searches the Space's emoji only, and says so.
Finder _search(String placeholder) => find.byWidgetPredicate(
  (w) =>
      w is AppInput &&
      (w.placeholder == placeholder ||
          w.placeholder == placeholder.replaceFirst('emoji', 'Space emoji')),
);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Insert emoji or a GIF'));
  await settle(tester);
}

Future<void> _openGifs(WidgetTester tester) async {
  await _openPicker(tester);
  await tester.tap(find.text('GIFs'));
  await settleRequest(tester);
}

Future<void> _typeInto(
  WidgetTester tester,
  String placeholder,
  String query,
) async {
  await tester.enterText(_search(placeholder), query);
  await settleRequest(tester);
}

void _picker(
  String state, {
  List<String> viewports = const ['phone', 'desktop'],
  List<Override> overrides = const [],
  required ReviewAct act,
}) => reviewCases(
  _surface,
  state: state,
  viewports: viewports,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewRoute(
      tester,
      surface: _surface,
      state: state,
      viewport: viewport,
      themes: themes,
      overrides: [
        ...composerSeeds(),
        ...favoriteSeeds(const []),
        ReviewServer().override,
        ...overrides,
      ],
      act: act,
    ),
  ),
);

final _kept = [
  favorite('f1', 'happy dance'),
  favorite(
    'f2',
    'harbour.png',
    kind: api.FavoriteKind.attachment,
    contentType: 'image/png',
  ),
  favorite('f3', 'thumbs up'),
  favorite(
    'f4',
    'clip.mp4',
    kind: api.FavoriteKind.attachment,
    contentType: 'video/mp4',
  ),
  favorite('f5', 'slow clap'),
  favorite('f6', 'facepalm'),
];

void main() {
  setUpAll(loadRealFonts);

  _picker('emoji', act: (tester, _) => _openPicker(tester));

  _picker(
    'emoji-no-match',
    act: (tester, _) async {
      await _openPicker(tester);
      await _typeInto(tester, 'Search emoji', 'zzqx');
    },
  );

  _picker('gifs', act: (tester, _) => _openGifs(tester));

  _picker(
    'gifs-results',
    act: (tester, _) async {
      await _openGifs(tester);
      await _typeInto(tester, 'Search GIFs', 'cats');
    },
  );

  _picker(
    'gifs-empty',
    act: (tester, _) async {
      await _openGifs(tester);
      await _typeInto(tester, 'Search GIFs', 'no-match');
    },
  );

  _picker(
    'gifs-error',
    overrides: [ReviewServer(failTrending: true).override],
    act: (tester, _) => _openGifs(tester),
  );

  _picker(
    'favorites',
    overrides: favoriteSeeds(_kept),
    act: (tester, _) => _openGifs(tester),
  );

  _picker(
    'favorites-empty',
    act: (tester, _) async {
      await _openGifs(tester);
      await tester.tap(find.byKey(GifPickerBody.favoritesToggleKey));
      await settle(tester);
    },
  );
}
