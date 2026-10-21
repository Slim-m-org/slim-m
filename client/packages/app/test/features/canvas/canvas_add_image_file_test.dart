// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Add image from file" places a picked picture, so a canvas has a way in
/// for images where the clipboard has none.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_picker.dart';

import '../composer/composer_harness.dart' show FakePlatformFile;
import 'canvas_pane_harness.dart';

void main() {
  testWidgets('a picked image file is uploaded and placed', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container(
      extraOverrides: [
        attachmentPickerProvider(
          AttachmentSource.stillImageFiles,
        ).overrideWithValue(
          () async => FakePlatformFile('photo.png', canvasPngFixture),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add image from file'));
    await tester.pump();
    // The decode and upload run on real async work.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(fixture.posted.map((o) => o['kind']), contains('image'));
  });
}
