// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reply and Edit put the caret where the user is about to type; they used to
/// leave focus wherever it was, which made the next keystroke go nowhere.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_edit_field.dart';
import 'package:slimm_app/src/widgets/reply_banner.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import 'channel_history_harness.dart';

final _canSend = [
  myChannelPermissionsProvider.overrideWith((ref, _) => Perm.sendMessages),
];

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tapAt(
    tester.getCenter(target),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await flush(tester);
}

EditableText? get _focusedField {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  if (context.widget is EditableText) return context.widget as EditableText;
  EditableText? found;
  context.visitAncestorElements((e) {
    if (e.widget is EditableText) found = e.widget as EditableText;
    return found == null;
  });
  return found;
}

Future<void> _openMenu(WidgetTester tester, {required bool touch}) async {
  final target = find.text('message 2');
  if (touch) {
    await tester.longPress(target);
    await flush(tester);
  } else {
    await _rightClick(tester, target);
  }
}

/// Drift's stream teardown leaves a zero-length timer that a bare end of test
/// reports as pending.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  for (final touch in [false, true]) {
    final how = touch ? 'long-press sheet' : 'right-click menu';
    testWidgets('Reply from the $how focuses the composer', (tester) async {
      await mountChannel(
        tester,
        serverSeqs: [1, 2],
        seededSeqs: [1, 2],
        syncStatus: SyncStatus.live,
        overrides: _canSend,
      );
      await tester.enterText(find.byType(TextField).last, 'draft');
      FocusManager.instance.primaryFocus?.unfocus();
      await flush(tester);

      await _openMenu(tester, touch: touch);
      await tester.tap(find.text('Reply').first);
      await flush(tester);

      expect(find.byType(ReplyBanner), findsOneWidget);
      final field = _focusedField;
      expect(field, isNotNull, reason: 'a text field holds focus');
      expect(field!.controller.text, 'draft');
      expect(field.controller.selection.baseOffset, 'draft'.length);
      await _unmount(tester);
    });

    testWidgets('Edit from the $how focuses the field, caret at the end', (
      tester,
    ) async {
      await mountChannel(
        tester,
        serverSeqs: [1, 2],
        seededSeqs: [1, 2],
        syncStatus: SyncStatus.live,
        authorFor: (_) => 'bob',
        overrides: _canSend,
      );
      // The composer holds focus, as it does after typing a message.
      await tester.tap(find.byType(TextField).last);
      await flush(tester);

      await _openMenu(tester, touch: touch);
      await tester.tap(find.text('Edit').first);
      await flush(tester);

      expect(find.byType(MessageEditField), findsOneWidget);
      final field = _focusedField;
      expect(field, isNotNull);
      expect(field!.controller.text, 'message 2');
      expect(field.controller.selection.baseOffset, 'message 2'.length);
      await _unmount(tester);
    });
  }
}
