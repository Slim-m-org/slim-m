// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Widget-level tests for the composer's attachment preview: a pick has to
/// stay on screen from the moment it happens, through upload, to whichever
/// of ready or failed resolves.
///
/// The owner's report, in order of what each test pins: a picked file used
/// to be invisible for the whole time between picking it and the upload
/// finishing on a slow connection, an image never got a preview at all, and
/// a failed upload had no way to say so or recover. `composer_attachments_
/// test.dart` covers [AttachmentStagingController] directly; these drive it
/// through the real widget tree, since a controller test alone cannot prove
/// the pending state actually reaches the screen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

/// A real 1x1 transparent PNG, so [Image.memory] decodes it rather than
/// falling back to the file glyph through its `errorBuilder`.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Finder _retryAttachmentButton(String filename) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Retry attaching $filename',
);

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets(
    'a picked file is visible immediately, before the upload resolves',
    (tester) async {
      final gate = Completer<void>();
      usePicker(pickedFile());
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          apiBuilder: gatedUploadApi(gate),
        ),
      );

      await tester.tap(attachButton);
      // Never `pumpAndSettle`: the upload is still gated and would hang it.
      await tester.pump();
      await tester.pump();

      expect(
        find.text('holiday.png'),
        findsOneWidget,
        reason:
            'a pick must appear before its upload has any chance to '
            'answer, or it reads as never having been attached at all',
      );
      expect(find.text('Uploading...'), findsOneWidget);
      expect(
        tester.widget<AppIconButton>(sendButton).onPressed,
        isNull,
        reason:
            'sending while an attachment is still uploading would send '
            'without it',
      );

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Uploading...'), findsNothing);
      expect(tester.widget<AppIconButton>(sendButton).onPressed, isNotNull);
    },
  );

  testWidgets('an image shows a thumbnail, needing no network', (tester) async {
    final gate = Completer<void>();
    usePicker(FakePlatformFile('photo.png', _pngBytes));
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: gatedUploadApi(gate),
      ),
    );

    await tester.tap(attachButton);
    await tester.pump();
    await tester.pump();
    // One more frame for the already-local bytes to decode.
    await tester.pump();

    expect(
      find.byType(Image),
      findsOneWidget,
      reason:
          'the bytes are already local at pick time; a thumbnail needs '
          'no network',
    );

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a non-image attachment shows a file glyph, not a thumbnail', (
    tester,
  ) async {
    usePicker(FakePlatformFile('notes.txt', Uint8List.fromList([1, 2, 3, 4])));
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );

    await tester.tap(attachButton);
    await tester.pumpAndSettle();

    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a failed upload shows a visible, recoverable error rather than '
      'disappearing', (tester) async {
    usePicker(pickedFile());
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        apiBuilder: flakyUploadApi(),
      ),
    );

    await tester.tap(attachButton);
    await tester.pumpAndSettle();

    expect(find.text('holiday.png'), findsOneWidget);
    expect(
      find.textContaining('Could not attach the file'),
      findsOneWidget,
      reason: 'a failed upload must say so in place, not vanish',
    );
    expect(
      tester.widget<AppIconButton>(sendButton).onPressed,
      isNull,
      reason:
          'a failed attachment still claims a slot until retried or '
          'removed',
    );

    await tester.tap(_retryAttachmentButton('holiday.png'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not attach the file'), findsNothing);
    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNotNull);
  });

  testWidgets('the existing send-with-attachment path still works', (
    tester,
  ) async {
    usePicker(pickedFile());
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
      ),
    );

    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(sends.count, 1);
    expect(sends.ids, ['a1']);
  });
}
