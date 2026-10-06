// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message row is one tab stop. Its avatar, name and toolbar buttons were
/// eight stops a message; they now ride the arrow keys inside the row, and the
/// context-menu key still opens every action. Driven with real key events.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/widgets/author_profile_tap_target.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _author = api.UserProfile(
  id: 'author-1',
  username: 'priya',
  displayName: 'Priya',
  createdAt: 0,
);

MessageActions _actions({VoidCallback? onReply}) => MessageActions(
  canReply: true,
  onReply: onReply ?? noop,
  canEdit: true,
  onEdit: noop,
  canDelete: false,
  onDelete: noop,
  canManagePins: false,
  pinned: false,
  onTogglePin: noop,
  canReport: false,
  onReport: noop,
  canBlockAuthor: false,
  onBlockAuthor: noop,
  canOpenThread: true,
  onOpenThread: noop,
  canCopyLink: false,
  onCopyLink: noop,
  canForward: false,
  onForward: noop,
  canSave: false,
  onSave: noop,
);

Widget _row({VoidCallback? onReply}) => MessageRow(
  message: message(),
  grouped: false,
  showNewDivider: false,
  knownUsernames: const {},
  actions: _actions(onReply: onReply),
  editing: false,
  callbacks: MessageRowCallbacks(
    onRetry: noop,
    onDiscard: noop,
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: (_) {},
    onCancelEdit: noop,
  ),
);

final _before = FocusNode(debugLabel: 'before');
final _after = FocusNode(debugLabel: 'after');

Future<void> _pump(WidgetTester tester, {VoidCallback? onReply}) async {
  await tester.pumpWidget(
    harness(
      Column(
        children: [
          TextField(focusNode: _before),
          _row(onReply: onReply),
          TextField(focusNode: _after),
        ],
      ),
      platform: TargetPlatform.linux,
      overrides: [
        userProfileProvider('author-1').overrideWith((ref) async => _author),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

bool _isFocused(FocusNode node) => node.hasPrimaryFocus;

/// The control focus sits on, by its own label; null on the row itself.
String? _focusedControl() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  final tap = context.findAncestorWidgetOfExactType<AuthorProfileTapTarget>();
  if (tap != null) return tap.semanticLabel;
  return context.findAncestorWidgetOfExactType<AppIconButton>()?.semanticLabel;
}

Future<void> _shiftTab(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
}

Future<void> _focusBefore(WidgetTester tester) async {
  await tester.tap(find.byType(TextField).first);
  await tester.pumpAndSettle();
  expect(_isFocused(_before), isTrue);
}

void main() {
  testWidgets('Tab crosses a whole message row in one stop', (tester) async {
    await _pump(tester);
    await _focusBefore(tester);

    var presses = 0;
    while (!_isFocused(_after) && presses < 15) {
      await _key(tester, LogicalKeyboardKey.tab);
      presses++;
      if (!_isFocused(_after)) expect(_focusedControl(), isNull);
    }
    expect(presses, 2, reason: 'row, then the field after it');
  });

  testWidgets('Right and Left walk the row controls in reading order', (
    tester,
  ) async {
    await _pump(tester);
    await _focusBefore(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    expect(_focusedControl(), isNull);

    const order = [
      'View profile',
      'Priya, view profile',
      'Add reaction',
      'Reply',
      'Reply in thread',
      'Edit',
      'More message actions',
    ];
    for (final label in order) {
      await _key(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusedControl(), label);
    }
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(
      _focusedControl(),
      'More message actions',
      reason: 'stops at the end',
    );

    for (final label in order.reversed.skip(1)) {
      await _key(tester, LogicalKeyboardKey.arrowLeft);
      expect(_focusedControl(), label);
    }
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focusedControl(), isNull, reason: 'back on the row');
  });

  testWidgets('Escape returns to the row and Enter runs a control', (
    tester,
  ) async {
    var replied = 0;
    await _pump(tester, onReply: () => replied++);
    await _focusBefore(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    for (var i = 0; i < 3; i++) {
      await _key(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(_focusedControl(), 'Add reaction');
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedControl(), 'Reply');
    await _key(tester, LogicalKeyboardKey.enter);
    expect(replied, 1);

    await _key(tester, LogicalKeyboardKey.escape);
    expect(_focusedControl(), isNull);
  });

  testWidgets('Tab and Shift+Tab from a control leave the row', (tester) async {
    await _pump(tester);
    await _focusBefore(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedControl(), 'Priya, view profile');

    await _key(tester, LogicalKeyboardKey.tab);
    expect(_isFocused(_after), isTrue);

    await _shiftTab(tester);
    expect(_focusedControl(), isNull);
    expect(_isFocused(_after), isFalse, reason: 'back on the row');

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedControl(), 'View profile');
    await _shiftTab(tester);
    expect(_isFocused(_before), isTrue);
  });

  testWidgets('the context-menu key opens every action from the row', (
    tester,
  ) async {
    await _pump(tester);
    await _focusBefore(tester);
    await _key(tester, LogicalKeyboardKey.tab);
    await _key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.byTooltip(ActionLabels.addReaction), findsOneWidget);
    for (final label in ['Reply', 'Reply in thread', 'Edit']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });
}
