// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Surfaces that draw sender-chosen pictures refuse one declaring a huge canvas
/// instead of allocating it, and a custom emoji keeps its own proportions.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/link_preview.dart';
import 'package:slimm_app/src/features/messages/widgets/cover_resize_image.dart';
import 'package:slimm_app/src/features/messages/widgets/link_preview_thumbnail.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_target_summary.dart';
import 'package:slimm_app/src/widgets/space_banner.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/declared_size_png.dart';

/// Well-formed, so only the size check stands between it and a 576 MB decode.
final _huge = solidPng(12000, 12000);

Widget _app(List<Override> overrides, Widget child) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump();
  }
}

Finder get _painted => find.byWidgetPredicate((w) => w is RawImage);

bool _drawsAPicture(WidgetTester tester) =>
    tester.widgetList<RawImage>(_painted).any((w) => w.image != null);

void main() {
  testWidgets('a 2:1 custom emoji keeps its proportions', (tester) async {
    await tester.pumpWidget(
      _app([
        customEmojiImageProvider.overrideWith(
          (ref, id) => Future<Uint8List>.value(solidPng(200, 100)),
        ),
      ], const CustomEmojiImage(emojiId: 'wide', size: 40)),
    );
    await _settle(tester);
    final image = tester.widget<RawImage>(_painted).image!;
    expect(image.width / image.height, closeTo(2, 0.05));
  });

  testWidgets('a huge Space banner draws nothing', (tester) async {
    await tester.pumpWidget(
      _app([
        spaceBannerBytesProvider.overrideWith((ref) async => _huge),
      ], const SpaceBanner(aspect: 3)),
    );
    await _settle(tester);
    expect(_drawsAPicture(tester), isFalse);
  });

  testWidgets('a huge link preview image draws its placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        [
          linkPreviewImageBytesProvider.overrideWith(
            (ref, token) async => _huge,
          ),
        ],
        const SizedBox(
          width: 300,
          height: 300,
          child: LinkPreviewThumbnail(
            token: 't',
            url: 'https://x.test',
            fill: true,
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(_drawsAPicture(tester), isFalse);
  });

  testWidgets('a huge reply target thumbnail falls back to its glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        [
          attachmentPreviewBytesProvider.overrideWith(
            (ref, key) async => _huge,
          ),
        ],
        const ReplyAttachmentThumb(
          attachments: [
            api.Attachment(
              id: 'a1',
              filename: 'big.png',
              contentType: 'image/png',
              size: 70,
            ),
          ],
          edge: 40,
        ),
      ),
    );
    await _settle(tester);
    expect(_drawsAPicture(tester), isFalse);
    expect(find.byIcon(AppIcons.image), findsOneWidget);
  });

  testWidgets('a reply thumbnail decodes by its shorter side, not squashed', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        [
          attachmentPreviewBytesProvider.overrideWith(
            (ref, key) async => solidPng(400, 100),
          ),
        ],
        const ReplyAttachmentThumb(
          attachments: [
            api.Attachment(
              id: 'a1',
              filename: 'wide.png',
              contentType: 'image/png',
              size: 70,
            ),
          ],
          edge: 40,
        ),
      ),
    );
    await _settle(tester);

    final image = tester.widget<Image>(
      find.byWidgetPredicate((w) => w is Image),
    );
    expect(image.image, isA<CoverResizeImage>());
  });
}
