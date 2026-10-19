// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Swipe-to-reply on real rows inside the real transcript, inside a scaffold
/// with the phone shell's drawers set up the way `CompactDrawerScaffold` does.
///
/// Every drag is a real touch gesture through hit testing and the gesture
/// arena. The first attempt at this feature could not reach its recogniser
/// through a row because the tests drove the row's centre, which is a text
/// span inside a selectable region; the drags here start on empty row space
/// (right of the text) the way a thumb does.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/drawer_edge_drag.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'message_row_harness.dart';
import '../../support/fake_sync.dart';

const _session = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _board = jsonEncode({
  r'$slim': 'scene/1',
  'width': 200,
  'height': 200,
  'ops': [
    {'op': 'rect', 'x': 0, 'y': 0, 'w': 200, 'h': 200, 'fill': 'sunken'},
  ],
  'controls': ['clear'],
});

class _Rig {
  final replies = <String>[];
  final drawerChanges = <bool>[];
  final scroll = ScrollController();
  final events = StreamController<api.ServerEvent>.broadcast();
}

MessageActions _actions(_Rig rig, Message m, {bool canReply = true}) =>
    MessageActions(
      canReply: canReply,
      onReply: () => rig.replies.add(m.id),
      canEdit: false,
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
      canOpenThread: false,
      onOpenThread: noop,
      canCopyLink: false,
      onCopyLink: noop,
      canForward: false,
      onForward: noop,
      canSave: true,
      onSave: noop,
    );

Future<_Rig> _pump(
  WidgetTester tester, {
  required List<Message> messages,
  double width = 390,
  Set<String> cannotReply = const {},
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final rig = _Rig();
  addTearDown(rig.events.close);
  addTearDown(rig.scroll.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _session)),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        liveEventsProvider.overrideWithValue(rig.events.stream),
        codeBlockRunnerProvider.overrideWith(
          (ref) async => const [
            api.CodeBlockRunner(
              moduleId: 'board',
              command: 'run',
              language: 'js',
            ),
          ],
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            drawer: const Drawer(child: Text('channel rail')),
            endDrawer: const Drawer(child: Text('members')),
            drawerEdgeDragWidth: drawerEdgeDragWidth(context),
            drawerDragStartBehavior: DragStartBehavior.down,
            onDrawerChanged: rig.drawerChanges.add,
            body: MessageTranscript(
              channelId: 'c1',
              messages: messages,
              syncStatus: SyncStatus.live,
              historyKnown: true,
              scrollController: rig.scroll,
              lastReadSeq: 999999,
              selfId: 'self',
              knownUsernames: const {},
              customEmoji: const {},
              history: const ChannelHistory(atStart: true),
              onLoadOlder: () {},
              onRetryOlder: () {},
              actionsFor: (m, _) =>
                  _actions(rig, m, canReply: !cannotReply.contains(m.id)),
              onRetry: (_) {},
              onDiscard: (_) {},
              onPickReaction: (_, _) {},
              onReactionTap: (_, _) {},
              onVote: (_, _) {},
              onSubmitEdit: (_, _) {},
              onCancelEdit: () {},
              onJumpToReply: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rig;
}

/// A point on empty row space right of the short text, at [id]'s vertical middle.
Offset _spot(WidgetTester tester, String id, {double x = 200}) {
  final row = find.byWidgetPredicate(
    (w) => w is MessageRow && w.message.id == id,
  );
  return Offset(x, tester.getCenter(row).dy);
}

Future<void> _drag(WidgetTester tester, Offset from, Offset by) async {
  final g = await tester.startGesture(from);
  const steps = 8;
  for (var i = 0; i < steps; i++) {
    await g.moveBy(by / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  final one = [message(id: 'm1', content: 'hi')];

  testWidgets('a rightward drag past the threshold replies to that row', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      messages: [
        message(id: 'm1', content: 'a'),
        message(id: 'm2'),
      ],
    );
    await _drag(tester, _spot(tester, 'm2'), const Offset(120, 4));
    expect(rig.replies, ['m2']);
    expect(rig.drawerChanges, isEmpty);
    expect(find.text('channel rail'), findsNothing);
  });

  testWidgets('a short drag springs back without replying', (tester) async {
    final rig = await _pump(tester, messages: one);
    await _drag(tester, _spot(tester, 'm1'), const Offset(30, 0));
    expect(rig.replies, isEmpty);
  });

  testWidgets('the row follows the finger and shows the reply icon', (
    tester,
  ) async {
    await _pump(tester, messages: one);
    final before = tester.getTopLeft(find.byType(MessageRow)).dx;
    final g = await tester.startGesture(_spot(tester, 'm1'));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byIcon(AppIcons.reply), findsOneWidget);
    final inner = tester.getTopLeft(find.byType(MessageRow)).dx;
    expect(
      inner,
      before,
      reason: 'the row widget stays put, its content moves',
    );
    final content = tester.getTopLeft(find.byType(MessageContextMenuRegion)).dx;
    expect(content, greaterThan(before + 20));
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(MessageContextMenuRegion)).dx, before);
  });

  testWidgets('a vertical drag scrolls the transcript and does not reply', (
    tester,
  ) async {
    final many = [
      for (var i = 0; i < 40; i++) message(id: 'm$i', content: 'x'),
    ];
    final rig = await _pump(tester, messages: many);
    final start = rig.scroll.offset;
    await _drag(tester, const Offset(200, 500), const Offset(8, 240));
    expect(rig.scroll.offset, isNot(start));
    expect(rig.replies, isEmpty);
  });

  testWidgets('a 45 degree diagonal drag scrolls and does not reply', (
    tester,
  ) async {
    final many = [
      for (var i = 0; i < 40; i++) message(id: 'm$i', content: 'x'),
    ];
    final rig = await _pump(tester, messages: many);
    await _drag(tester, const Offset(200, 400), const Offset(160, 160));
    expect(rig.scroll.offset, greaterThan(0));
    expect(rig.replies, isEmpty);
  });

  testWidgets('a leftward drag does nothing', (tester) async {
    final rig = await _pump(tester, messages: one);
    await _drag(tester, _spot(tester, 'm1', x: 300), const Offset(-150, 0));
    expect(rig.replies, isEmpty);
    expect(rig.drawerChanges, isEmpty);
  });

  testWidgets('a rightward drag from the left edge opens the drawer instead', (
    tester,
  ) async {
    final rig = await _pump(tester, messages: one);
    await _drag(tester, _spot(tester, 'm1', x: 4), const Offset(220, 0));
    expect(rig.replies, isEmpty);
    expect(rig.drawerChanges, [true]);
  });

  testWidgets('a row that cannot be replied to does not swipe', (tester) async {
    final rig = await _pump(tester, messages: one, cannotReply: {'m1'});
    await _drag(tester, _spot(tester, 'm1'), const Offset(150, 0));
    expect(rig.replies, isEmpty);
  });

  testWidgets('pending and failed rows do not swipe', (tester) async {
    final rig = await _pump(
      tester,
      messages: [
        message(id: 'p', pending: true),
        message(id: 'f', failed: true),
      ],
    );
    await _drag(tester, _spot(tester, 'p'), const Offset(150, 0));
    await _drag(tester, _spot(tester, 'f'), const Offset(150, 0));
    expect(rig.replies, isEmpty);
  });

  testWidgets('wide layouts have no swipe', (tester) async {
    final rig = await _pump(tester, messages: one, width: 900);
    await _drag(tester, _spot(tester, 'm1', x: 500), const Offset(150, 0));
    expect(rig.replies, isEmpty);
  });

  testWidgets('a drag on a module board draws and does not reply', (
    tester,
  ) async {
    final rig = await _pump(
      tester,
      messages: [message(id: 'b', content: '```js\n1\n```')],
    );
    rig.events.add(
      api.CodeRunChanged(
        channelId: 'c1',
        messageId: 'b',
        run: api.CodeRun(
          blockIndex: 0,
          moduleId: 'board',
          command: 'run',
          ok: true,
          output: _board,
          ranBy: 'u1',
          ranAt: 1700000000000,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final board = find.byType(ModuleSceneView);
    expect(board, findsOneWidget);
    await _drag(
      tester,
      tester.getCenter(board) - const Offset(40, 0),
      const Offset(120, 6),
    );
    expect(rig.replies, isEmpty);
  });
}
