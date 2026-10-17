// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Measures whether starting an inline edit rebuilds message rows that are
/// not the one being edited.
///
/// `_editingId` used to be a plain field on `_ChannelScreenState`, so every
/// `setState` that changed it re-ran the whole `StreamBuilder<List<Message>>`
/// subtree, which reconstructs every visible `MessageRow` (and re-parses its
/// markdown body) regardless of whether that row's own `editing` flag
/// actually flipped. `debugOnRebuildDirtyWidget` is the framework's own
/// per-element rebuild hook (used by the widget inspector), and it is used
/// here rather than any counter added to production code, so nothing under
/// test needed to change shape to be measurable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';

import '../../channel_history_harness.dart';

/// Tears the tree down properly so nothing outlives the test: the same
/// `_unmount` shape `message_extras_batch_test.dart` already uses, since
/// `mountChannel` starts timers (the scroll tracker, the sync controller)
/// that a bare `pumpWidget` swap does not cancel synchronously.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// How many times a widget of type [T] was rebuilt while [action] ran.
Future<int> _rebuildsOf<T extends Widget>(
  Future<void> Function() action,
) async {
  var count = 0;
  final previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget.runtimeType == T) count++;
  };
  try {
    await action();
  } finally {
    debugOnRebuildDirtyWidget = previous;
  }
  return count;
}

/// Opens [messageId]'s context menu by the same long-press gesture a touch
/// user would make, and taps [label] in it. A bounded pump, not
/// `pumpAndSettle`: once the tapped item is Edit, the row's new
/// `MessageEditField` keeps a cursor-blink frame scheduled forever, which
/// `pumpAndSettle` never returns past.
Future<void> _openMenuAndTap(
  WidgetTester tester,
  String messageId,
  String label,
) async {
  final region = find.descendant(
    of: find.byKey(ValueKey(messageId)),
    matching: find.byType(MessageContextMenuRegion),
  );
  await tester.longPress(region);
  await flush(tester);
  await tester.tap(find.text(label));
  await flush(tester);
}

void main() {
  testWidgets('editing one message does not rebuild every other message body', (
    tester,
  ) async {
    await mountChannel(
      tester,
      serverSeqs: [for (var i = 1; i <= 8; i++) i],
      seededSeqs: [for (var i = 1; i <= 8; i++) i],
      messageAuthorId: 'bob',
    );

    // Includes opening the menu, which is one legitimate same-row rebuild.
    final rebuilds = await _rebuildsOf<MessageBody>(
      () => _openMenuAndTap(tester, 'm4', 'Edit'),
    );

    expect(
      rebuilds,
      lessThanOrEqualTo(1),
      reason:
          'starting an edit on one message must not re-parse the markdown '
          'of every other visible row; at most the edited row\'s own '
          'MessageBody may rebuild once, from opening its own menu, before '
          'it swaps to the edit field',
    );

    await _unmount(tester);
  });
}
