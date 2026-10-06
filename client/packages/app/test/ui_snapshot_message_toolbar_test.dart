// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hovered message row's toolbar at desktop width in both themes: a full
/// row, a grouped continuation row, and the first row of a transcript. PNGs
/// are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts each
/// scene lays out without overflow.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_hover_toolbar.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';
import 'ui_snapshot_support.dart';

MessageActions get _own => MessageActions(
  canReply: true,
  onReply: noop,
  canEdit: true,
  onEdit: noop,
  canDelete: true,
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
  canForward: true,
  onForward: noop,
  canSave: true,
  onSave: noop,
);

Widget _row(String id, String content, {bool grouped = false}) => MessageRow(
  key: ValueKey(id),
  message: message(id: id, content: content),
  grouped: grouped,
  showNewDivider: false,
  knownUsernames: const {},
  actions: _own,
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

void main() {
  setUpAll(loadRealFonts);

  const scenes = {'row': 'b', 'grouped': 'c', 'first': 'a'};
  for (final dark in const [true, false]) {
    final mode = dark ? 'dark' : 'light';
    for (final scene in scenes.entries) {
      testWidgets('hovered ${scene.key} row ($mode)', (tester) async {
        tester.view.physicalSize = const Size(1000, 360);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: dark
                    ? buildTheme(Brightness.dark, AppTokens.dark)
                    : buildTheme(Brightness.light, AppTokens.light),
                home: Scaffold(
                  body: ListView(
                    children: [
                      _row('a', 'morning, did anyone look at the canvas bug'),
                      _row('b', 'yes, it was the seq ordering on resync'),
                      _row('c', 'fix is up in the PR', grouped: true),
                      _row('d', 'and a second line in the run', grouped: true),
                      _row('e', 'thanks, merging after ci'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(-50, -50));
        await mouse.moveTo(
          tester.getCenter(find.byKey(ValueKey(scene.value))) -
              const Offset(300, 0),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(MessageHoverToolbar.plateKey), findsOneWidget);
        await writeSnapshot(tester, 'message-toolbar-${scene.key}-$mode');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
