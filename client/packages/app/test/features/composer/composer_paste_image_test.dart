// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for pasting an image into the composer.
///
/// A widget test cannot produce a real browser `paste` event, so these
/// drive the same seam `Composer` itself calls
/// (`Composer.clipboardPasteStart`/`clipboardPasteStop`) through
/// [FakeClipboardPaste], which stands in for
/// `composer_clipboard_image_web.dart`'s real listener. What is under test
/// is the composer's own wiring: arming only while focused, and staging a
/// pasted image through the exact path a picked file already uses.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

final _bytes = Uint8List.fromList([1, 2, 3, 4]);

void main() {
  late TextEditingController controller;
  late Sends sends;
  late FakeClipboardPaste clipboardPaste;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
    clipboardPaste = FakeClipboardPaste();
  });

  tearDown(() => controller.dispose());

  testWidgets('pasting an image while focused stages it as an attachment', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        clipboardPaste: clipboardPaste,
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(
      clipboardPaste.listening,
      isTrue,
      reason: 'the seam must arm the moment the field takes focus',
    );

    clipboardPaste.paste(_bytes, 'screenshot.png');
    await tester.pumpAndSettle();

    expect(find.text('screenshot.png'), findsOneWidget);
    expect(
      tester.widget<AppIconButton>(sendButton).onPressed,
      isNotNull,
      reason:
          'a pasted image needs no caption to be worth sending, same '
          'as a picked one',
    );

    await tester.tap(sendButton);
    await tester.pumpAndSettle();
    expect(sends.count, 1);
    expect(sends.ids, ['a1']);
  });

  testWidgets('the paste seam disarms once the field loses focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        clipboardPaste: clipboardPaste,
      ),
    );

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(clipboardPaste.listening, isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    expect(
      clipboardPaste.listening,
      isFalse,
      reason:
          'a single global listener must not outlive the focus that '
          'armed it',
    );
    expect(clipboardPaste.stopCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('a paste while nothing is focused reaches no attachment', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        clipboardPaste: clipboardPaste,
      ),
    );

    expect(clipboardPaste.listening, isFalse);
    clipboardPaste.paste(_bytes, 'screenshot.png');
    await tester.pumpAndSettle();

    expect(find.text('screenshot.png'), findsNothing);
  });
}
