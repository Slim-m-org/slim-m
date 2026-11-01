// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for attaching a file from the composer. The button beside it, the
/// Space emoji sheet, has its own file.
///
/// The defects these pin: a staged photo with no caption left the send button
/// dead, and picking a file took the caret away for good, on every one of the
/// three ways the pick can end.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

/// The staged-attachment tile's remove control, found by its accessibility
/// label rather than a widget type, since [Semantics] is a proxy the tree
/// already carries regardless of whether a test enables the semantics tree.
Finder removeAttachmentButton(String filename) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == 'Remove attachment $filename',
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

  group('attachments', () {
    // The defect: _canSend read the text field alone, so a staged photo with
    // no caption left the send button dead and the message unsendable.
    testWidgets('a staged attachment alone enables the send button', (
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

      expect(tester.widget<AppIconButton>(sendButton).onPressed, isNull);

      await tester.tap(attachButton);
      await tester.pumpAndSettle();

      expect(find.text('holiday.png'), findsOneWidget);
      expect(
        tester.widget<AppIconButton>(sendButton).onPressed,
        isNotNull,
        reason: 'a photo needs no caption to be worth sending',
      );
    });

    testWidgets('sending with no text still carries the attachment id', (
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
      expect(controller.text, isEmpty);
    });

    testWidgets('removing the last attachment disables the button again', (
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
      expect(tester.widget<AppIconButton>(sendButton).onPressed, isNotNull);

      await tester.tap(removeAttachmentButton('holiday.png'));
      await tester.pump();

      expect(tester.widget<AppIconButton>(sendButton).onPressed, isNull);
    });

    // The owner's report: the caret leaves the input once a file is picked,
    // and typing goes nowhere.
    testWidgets('focus returns to the field after a pick', (tester) async {
      usePicker(pickedFile());
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(fieldHasFocus(tester), isTrue);

      // What the native picker does to focus while it is open, which no
      // widget test can produce on its own.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(fieldHasFocus(tester), isFalse);

      await tester.tap(attachButton);
      await tester.pumpAndSettle();

      expect(
        fieldHasFocus(tester),
        isTrue,
        reason: 'the caret must come back, or the next keystroke is lost',
      );
    });

    testWidgets('focus returns after a cancelled pick too', (tester) async {
      final picker = usePicker(null);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await tester.tap(attachButton);
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(removeAttachmentButton('holiday.png'), findsNothing);
      expect(
        fieldHasFocus(tester),
        isTrue,
        reason: 'changing your mind must not cost the caret either',
      );
    });

    // The third way a pick ends, and the one the other two do not cover: the
    // picker never answers at all. A missing xdg portal does this.
    testWidgets('focus returns, and the failure is said, when the picker '
        'throws', (tester) async {
      final picker = usePicker(null, failure: StateError('no portal'));
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await tester.tap(attachButton);
      await tester.pumpAndSettle();

      expect(picker.calls, 1);
      expect(
        find.textContaining('Could not open the file picker'),
        findsOneWidget,
        reason: 'a pick that never opened has to say so, not fail silently',
      );
      // Stays on screen, not a SnackBar that floats away with no record.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(
        fieldHasFocus(tester),
        isTrue,
        reason: 'a broken picker must not cost the caret either',
      );
    });

    // The owner's report: the attach button on a phone only opened Files.
    testWidgets('the sheet routes Photo library and Browse files to '
        'different requests', (tester) async {
      // Touch density, and so the sheet at all, follows width; see AppTouchTargets.of.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final picker = usePicker(pickedFile());
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.iOS,
        ),
      );

      await tester.tap(moreActionsButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photo library'));
      await tester.pumpAndSettle();

      expect(picker.lastType, FileType.image);

      await tester.tap(moreActionsButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browse files'));
      await tester.pumpAndSettle();

      expect(
        picker.lastType,
        isNot(FileType.image),
        reason: 'the document browser must not be asked to filter to Photos',
      );
    });

    // Proven at the width where the band's own space is actually scarce.
    testWidgets(
      'the inline failure fits at phone width, reached through the sheet',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        usePicker(null, failure: StateError('no portal'));
        await tester.pumpWidget(
          composerHarness(
            controller: controller,
            sends: sends,
            platform: TargetPlatform.iOS,
          ),
        );

        await tester.tap(moreActionsButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Photo library'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(SnackBar), findsNothing);
        expect(find.byType(AppErrorState), findsOneWidget);
      },
    );
  });
}
