// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's Favorites tab at desktop and phone width, with a GIF, a kept
/// image, a kept video and an unavailable entry, and the phone long-press menu.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_picker_panel.dart';
import 'package:slimm_app/src/features/favorites/providers/favorite_preview_bytes.dart';
import 'package:slimm_app/src/features/favorites/providers/favorites_controller.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/composer/providers/gif_trending.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

api.Favorite _fav(
  String id,
  String title, {
  api.FavoriteKind kind = api.FavoriteKind.gif,
  String? contentType,
  bool available = true,
}) => api.Favorite(
  id: id,
  kind: kind,
  title: title,
  width: 100,
  height: 100,
  available: available,
  createdAt: 1,
  attachmentId: kind == api.FavoriteKind.attachment ? 'ab' * 32 : null,
  contentType: contentType,
);

class _Seeded extends FavoritesController {
  @override
  Future<List<api.Favorite>> build() async => [
    _fav('1', 'happy dance'),
    _fav(
      '2',
      'harbour.png',
      kind: api.FavoriteKind.attachment,
      contentType: 'image/png',
    ),
    _fav(
      '3',
      'clip.mp4',
      kind: api.FavoriteKind.attachment,
      contentType: 'video/mp4',
    ),
    _fav(
      '4',
      'gone.png',
      kind: api.FavoriteKind.attachment,
      contentType: 'image/png',
      available: false,
    ),
    _fav('5', 'thumbs up'),
    _fav('6', 'slow clap'),
  ];
}

Future<void> _capture(
  WidgetTester tester,
  Size size,
  String name, {
  bool menu = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        favoritesProvider.overrideWith(_Seeded.new),
        favoritePreviewBytesProvider.overrideWith((ref, id) async => _png),
        attachmentPreviewBytesProvider.overrideWith((ref, key) async => _png),
        trendingGifsProvider.overrideWith((ref, channelId) async => const []),
      ],
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Center(
              child: ComposerPickerPanel(
                initialTab: ComposerPickerTab.gif,
                onSelectEmoji: (_) {},
                onPickedGif: (_) {},
                onClose: () {},
                width: size.width < 600 ? size.width - 32 : 480,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump(const Duration(milliseconds: 350));
  if (menu) {
    await tester.longPress(find.byKey(const ValueKey('favorite-2')));
    await tester.pump(const Duration(milliseconds: 400));
  }
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('desktop favorites tab', (tester) async {
    await _capture(tester, const Size(1440, 900), 'favorites-desktop');
  });

  testWidgets('phone favorites tab', (tester) async {
    await _capture(tester, const Size(390, 844), 'favorites-phone');
  });

  testWidgets('phone favorites menu', (tester) async {
    await _capture(
      tester,
      const Size(390, 844),
      'favorites-phone-menu',
      menu: true,
    );
  });
}
