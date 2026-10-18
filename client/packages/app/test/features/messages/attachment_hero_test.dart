// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment thumbnail's hero flight into the fullscreen viewer, and
/// the tag choice that makes it safe: each mounted thumbnail mints its own
/// identity tag, so the same content-addressed image shown twice never puts
/// two identical hero tags in one subtree - the exact throw the viewer's
/// own doc used to trade the flight away to avoid.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_design_system/design_system.dart';

const _attachment = api.Attachment(
  id: 'a1',
  filename: 'photo.png',
  contentType: 'image/png',
  size: 4,
);

/// A one-pixel PNG, so the thumbnail decodes for real and the tap target is
/// the image rather than its failure box.
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

Future<void> _pump(WidgetTester tester, {int copies = 1}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        attachmentBytesProvider(
          _attachment.id,
        ).overrideWith((ref) async => Uint8List.fromList(_png)),
        attachmentPreviewBytesProvider.overrideWith(
          (ref, key) async => Uint8List.fromList(_png),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Column(
            children: [
              for (var i = 0; i < copies; i++)
                const AttachmentView(attachment: _attachment),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the thumbnail and the viewer share one identity hero tag', (
    tester,
  ) async {
    await _pump(tester);
    final thumbTag = tester.widget<Hero>(find.byType(Hero)).tag;

    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();

    expect(find.byType(FullscreenImageViewer), findsOneWidget);
    final viewerHero = tester.widget<Hero>(
      find.descendant(
        of: find.byType(FullscreenImageViewer),
        matching: find.byType(Hero),
      ),
    );
    expect(viewerHero.tag, same(thumbTag));
  });

  testWidgets('the same image twice on screen opens without a tag clash', (
    tester,
  ) async {
    await _pump(tester, copies: 2);
    // Two mounted thumbnails of one content-addressed attachment: two tags.
    final tags = tester
        .widgetList<Hero>(find.byType(Hero))
        .map((h) => h.tag)
        .toSet();
    expect(tags, hasLength(2));

    await tester.tap(find.byType(Image).first);
    // Mid-flight and settled: no duplicate-tag throw either side.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
    expect(find.byType(FullscreenImageViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
