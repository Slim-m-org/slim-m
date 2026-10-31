// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's single attachment-error band now carries both a
/// clipboard-paste failure and a file-picker failure (`_ComposerState`'s own
/// doc comment on `_attachmentError`), sharing one `String?` field and one
/// `ComposerInlineError`. `composer_clipboard_paste.dart`'s `pasteClipboardImage`
/// clears that field up front, "so a retry that succeeds does not leave a
/// stale failure on screen" - its own doc comment says so in those words.
/// `runAttachmentPick` (`attachment_picker.dart`) has no equivalent: it only
/// ever calls `onPickerFailed`, never clears anything on a later success.
/// This is what proves whether that asymmetry actually leaves a stale error
/// on screen after a retried pick succeeds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

void main() {
  testWidgets(
    'a picker retry that succeeds clears the earlier failure banner',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final sends = Sends();

      usePicker(null, failure: StateError('no portal'));
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
        ),
      );

      await tester.tap(attachButton);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not open the file picker'),
        findsOneWidget,
        reason: 'the first, real failure must still be said',
      );

      usePicker(pickedFile());
      await tester.tap(attachButton);
      await tester.pumpAndSettle();

      expect(
        find.text('holiday.png'),
        findsOneWidget,
        reason: 'the retry must actually stage the file',
      );
      expect(
        find.byType(AppErrorState),
        findsNothing,
        reason:
            'reproduction: a picker failure that already happened once must '
            'not keep reading as still-broken after a retry succeeds',
      );
    },
  );
}
