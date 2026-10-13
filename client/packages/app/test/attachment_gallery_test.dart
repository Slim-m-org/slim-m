// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Several images on one message make a compact grid; one image, and every
/// file that is not an image, still shows the way it always did.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/attachment_bytes.dart';
import 'package:slimm_app/src/widgets/attachment_gallery.dart';
import 'package:slimm_app/src/widgets/attachment_view.dart';
import 'package:slimm_app/src/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_design_system/design_system.dart';

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

api.Attachment _image(int i) => api.Attachment(
  id: 'img-$i',
  filename: 'photo-$i.png',
  contentType: 'image/png',
  size: 4,
);

const _pdf = api.Attachment(
  id: 'doc',
  filename: 'notes.pdf',
  contentType: 'application/pdf',
  size: 2048,
);

Future<void> _pump(
  WidgetTester tester,
  List<api.Attachment> attachments, {
  double width = 700,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        for (final a in attachments)
          attachmentBytesProvider(
            a.id,
          ).overrideWith((ref) async => Uint8List.fromList(_png)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MessageAttachments(attachments: attachments),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Rect> _tiles(WidgetTester tester) => tester
    .widgetList<AttachmentView>(find.byType(AttachmentView))
    .where((v) => v.tileEdge != null)
    .map((v) => tester.getRect(find.byWidget(v)))
    .toList();

void main() {
  testWidgets('one image keeps its own size and caption, no gallery', (
    tester,
  ) async {
    await _pump(tester, [_image(0)]);
    expect(find.byType(AttachmentGallery), findsNothing);
    expect(find.textContaining('photo-0.png'), findsOneWidget);
  });

  for (final (count, perRow) in [(2, 2), (3, 3), (4, 2)]) {
    testWidgets('$count images sit $perRow to a row as equal squares', (
      tester,
    ) async {
      await _pump(tester, [for (var i = 0; i < count; i++) _image(i)]);
      final tiles = _tiles(tester);
      expect(tiles, hasLength(count));
      for (final tile in tiles) {
        expect(tile.width, moreOrLessEquals(tiles.first.width));
        expect(tile.height, moreOrLessEquals(tile.width));
      }
      final firstRow = tiles.where((t) => t.top == tiles.first.top).length;
      expect(firstRow, perRow);
      expect(find.textContaining('.png ·'), findsNothing);
    });
  }

  testWidgets('past four, the last tile says how many more', (tester) async {
    await _pump(tester, [for (var i = 0; i < 6; i++) _image(i)]);
    expect(_tiles(tester), hasLength(kGalleryMaxTiles));
    expect(find.text('+2'), findsOneWidget);
  });

  testWidgets('a tile opens the viewer on that image, paging through all', (
    tester,
  ) async {
    await _pump(tester, [for (var i = 0; i < 3; i++) _image(i)]);
    await tester.tap(find.byType(Image).at(1));
    await tester.pumpAndSettle();
    final viewer = tester.widget<FullscreenImageViewer>(
      find.byType(FullscreenImageViewer),
    );
    expect(viewer.index, 1);
    expect(viewer.images, hasLength(3));
  });

  testWidgets('a file beside the images still shows on its own', (
    tester,
  ) async {
    await _pump(tester, [_image(0), _pdf, _image(1)]);
    expect(find.byType(AttachmentGallery), findsOneWidget);
    expect(_tiles(tester), hasLength(2));
    expect(find.text('notes.pdf'), findsOneWidget);
  });

  testWidgets('in a narrow column the tiles shrink to fit on one row', (
    tester,
  ) async {
    await _pump(tester, [for (var i = 0; i < 3; i++) _image(i)], width: 300);
    expect(tester.takeException(), isNull);
    final tiles = _tiles(tester);
    expect(tiles.map((t) => t.top).toSet(), hasLength(1));
    expect(tiles.last.right, lessThanOrEqualTo(300));
  });
}
