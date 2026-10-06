// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's "Paste image" row end to end: whether it appears, what
/// tapping it stages, what a platform read failure shows, and that
/// `ClipboardPasteBridge.m`'s edit-menu swizzle installing successfully
/// never hides it - that signal was found 2026-08-01 not to prove the menu
/// item it targets actually appears, and withdrawing the row on it left no
/// way to paste an image at all. See `composer_clipboard_paste.dart`'s doc
/// comment.
///
/// Driven at the same `top.npcserver.slimm/clipboard_image` method channel
/// `composer_clipboard_image_test.dart` proves at the seam level, so the
/// Swift and Kotlin sides need no device to test the Dart contract they are
/// called under - the same shape `attachment_picker_test.dart` and
/// `emoji_upload_file_picker_test.dart` already use for `file_picker`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

const _channel = MethodChannel('top.npcserver.slimm/clipboard_image');

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, handler);
}

/// Taps the composer's "+" button and settles the sheet it opens. Requires
/// a phone-sized viewport: "More actions" (this row) only renders at touch
/// density, and the composer harness leaves the window at its desktop-sized
/// test default otherwise - see [_useTouchViewport].
Future<void> _openActionsSheet(WidgetTester tester) async {
  await tester.tap(moreActionsButton);
  await tester.pumpAndSettle();
}

void _useTouchViewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() {
    controller.dispose();
    _mock(null);
  });

  testWidgets('the row is absent when the clipboard holds no image', (
    tester,
  ) async {
    _useTouchViewport(tester);
    _mock((call) async => call.method == 'hasImage' ? false : null);

    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );
    await _openActionsSheet(tester);

    expect(find.text('Paste image'), findsNothing);
  });

  testWidgets(
    'the row appears when the clipboard holds an image, and stages it like '
    'a picked file',
    (tester) async {
      _useTouchViewport(tester);
      _mock((call) async {
        if (call.method == 'hasImage') return true;
        if (call.method == 'readImage') {
          return Uint8List.fromList([1, 2, 3, 4]);
        }
        return null;
      });

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );
      await _openActionsSheet(tester);
      expect(find.text('Paste image'), findsOneWidget);

      await tester.tap(find.text('Paste image'));
      await tester.pumpAndSettle();

      // `pasteClipboardImage` names every pasted image this, unconditionally.
      expect(find.text('pasted-image.png'), findsOneWidget);
    },
  );

  testWidgets(
    'a read failure shows a visible, dismissible error rather than nothing',
    (tester) async {
      _useTouchViewport(tester);
      _mock((call) async {
        if (call.method == 'hasImage') return true;
        if (call.method == 'readImage') {
          throw PlatformException(
            code: 'read_failed',
            message:
                'The app that copied this image did not allow it to '
                'be read.',
          );
        }
        return null;
      });

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );
      await _openActionsSheet(tester);
      await tester.tap(find.text('Paste image'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'The app that copied this image did not allow it to be read.',
        ),
        findsOneWidget,
      );
      expect(find.byType(AppErrorState), findsOneWidget);

      // Dismissing clears it and leaves the composer otherwise usable.
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.byType(AppErrorState), findsNothing);
    },
  );
}
