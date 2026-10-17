// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Image spoilers: a staged image can be marked, the send carries which ids
/// are spoilers, and a spoiler in the transcript stays blurred and inert
/// until the viewer taps it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_spoiler.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart';
import 'package:slimm_app/src/features/composer/widgets/staged_attachment_tile.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

api.Attachment _image(String id, {bool spoiler = false}) => api.Attachment(
  id: id,
  filename: 'ending-$id.png',
  contentType: 'image/png',
  size: _png.length,
  spoiler: spoiler,
);

Future<void> _pumpView(
  WidgetTester tester,
  api.Attachment attachment, {
  String theme = 'light',
  Size size = const Size(520, 420),
  Uint8List? bytes,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tokens = theme == 'dark' ? AppTokens.dark : AppTokens.light;
  await tester.pumpWidget(
    RepaintBoundary(
      key: snapshotBoundary,
      child: ProviderScope(
        overrides: [
          attachmentBytesProvider(
            attachment.id,
          ).overrideWith((ref) async => bytes ?? _png),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            theme == 'dark' ? Brightness.dark : Brightness.light,
            tokens,
          ),
          home: Scaffold(
            backgroundColor: tokens.surfaceBase,
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.s16),
              child: Align(
                alignment: Alignment.topLeft,
                child: AttachmentView(attachment: attachment),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Image decoding runs outside the fake clock; give it real time, then paint.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);

  test('a send carries the staged spoilers by their uploaded ids', () async {
    final staging =
        AttachmentStagingController(
            upload: (_, _, _) => throw StateError('unused'),
          )
          ..addResolved(_image('a1'), _png)
          ..addResolved(_image('a2'), _png);
    staging.toggleSpoiler(staging.items[1].localId);

    StagedSend? sent;
    await staging.sendReady((staged) async => sent = staged);

    expect(sent!.ids, ['a1', 'a2']);
    expect(sent!.spoilerIds, ['a2']);
  });

  testWidgets('the staged tile toggles its spoiler and says which way', (
    tester,
  ) async {
    var toggled = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: StagedAttachmentTile(
            attachment: UploadedAttachment(
              localId: 'l1',
              filename: 'ending.png',
              body: AttachmentBody.memory(_png),
              attachment: _image('a1'),
            ),
            onRemove: () {},
            onRetry: () {},
            spoiler: true,
            onToggleSpoiler: () => toggled++,
          ),
        ),
      ),
    );
    final toggle = find.bySemanticsLabel('Show ending.png without a spoiler');
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    expect(toggled, 1);
  });

  testWidgets('a spoiler stays covered until tapped, then shows the image', (
    tester,
  ) async {
    await _pumpView(tester, _image('a1', spoiler: true));
    expect(find.byType(AttachmentSpoilerCover), findsOneWidget);
    expect(find.text('Spoiler'), findsOneWidget);

    await tester.tap(find.byType(AttachmentSpoilerCover));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentSpoilerCover), findsNothing);
    expect(find.text('Spoiler'), findsNothing);
  });

  testWidgets('an ordinary image has no cover', (tester) async {
    await _pumpView(tester, _image('a1'));
    expect(find.byType(AttachmentSpoilerCover), findsNothing);
  });

  for (final theme in ['dark', 'light']) {
    for (final (label, size) in [
      ('desktop', const Size(520, 420)),
      ('phone', const Size(390, 420)),
    ]) {
      testWidgets('attachment-spoiler-$theme-$label renders', (tester) async {
        await _pumpView(
          tester,
          _image('a1', spoiler: true),
          theme: theme,
          size: size,
          bytes: _sample(),
        );
        await writeSnapshot(tester, 'attachment-spoiler-$theme-$label');
        expect(tester.takeException(), isNull);
      });
    }
  }
}

/// A small, colourful image, so the blur has something to visibly soften.
Uint8List _sample() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAKAAAABkCAIAAACO1KzYAAACf0lEQVR42u3dvXHCMBjGcZljDupUTMAIKVJReIRMwAhMkDoVBVWKDEHtKnUmYIQUyRE4CGBFH+/76P/UuRyn3z2yLNnnbta/BqKbCUMAMAGYAEwAJgATgAnAABOACcAEYAIwAZj8mamR3zH06+t/MN+s0IpIV/E8+CYq2F6Bo2lhNg2cxBVpo4usTLpZ/zMNtgVAlSs0uGS9qHJp4PIjjnE54FpjjXEJ4LqjjHFeYAvji3EuYDsji3F6YGtjivFEfjQbN+a4MLCTpVCUuE2u7efGheJy1udtsP1psNmJmikaYNI4sJfZr81ZmgYDLFSLBktMgwEmbjO8PE0ZBUnXkOTBd4+XtKFfqz66dexq7s0GEp2H9+0QzL+6QiJcg6N3k0haV4D1aUMI8+c3gDVdabC4K8A6rh+PyysH/gA7dmWRJeh6Py3Ayq5pgOeblbvdyor7lCVdabC4K8DirgCLuyYD9nUZznoBznerQ4M1b2GtAHspcdr6GnelweKuAIu7Jga2P0vHzc/WlsQ1G2zZeKzuxafXfLkyRYu7ZgG2WeKb9ZV0zdVga8ZXdLVdM07Rdowv6jbimvcabMH4XDeC1q9r9kVWXeNj3QjXw9Nr2xAANmf8rfsf18BXV+waL3bDAteC98GFjBc7+lpto+NnzszBPN61HdrSO1kpq4yrza3Kw+I2UhpXL3vR4yZtXJ0eNpzcrZ5j46p0mvQ7e0dtJeLq4LiQrQlNYFw1gXHVBMZVExhXTWCWxJrAuGoC46oJjKsmMK6awLjKAnOrowmMqyYwrprAuIb7PvroDBhX1XT7/R5aVtG46gLjqgmMq84n3o9XWLhqNhhX5QYzCsL5AhQUOuvh2DycAAAAAElFTkSuQmCC',
);
