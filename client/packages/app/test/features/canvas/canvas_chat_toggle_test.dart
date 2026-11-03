// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas can open its voice channel's chat (decision: a docked pane
/// where there is room, a sheet narrower) and says when a message waits.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_overflow_menu.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_chat_toggle.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Channel _channel({
  String kind = 'voice',
  int cursor = 0,
  int lastRead = 0,
  int mentioned = 0,
}) => Channel(
  id: 'c1',
  name: 'claude-draw-test',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: lastRead,
  mentionedSeq: mentioned,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Channel channel, {
  double width = 1600,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      channelByIdProvider('c1').overrideWith((ref) => Stream.value(channel)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: CanvasBar(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('a voice channel canvas offers the chat toggle in its header, '
      'and it drives the docked pane', (tester) async {
    final container = await _pump(tester, _channel());
    expect(find.bySemanticsLabel('Toggle text chat'), findsOneWidget);
    expect(container.read(voiceChatPaneVisibleProvider), isFalse);

    await tester.tap(find.bySemanticsLabel('Toggle text chat'));
    await tester.pump();
    expect(container.read(voiceChatPaneVisibleProvider), isTrue);

    await tester.tap(find.bySemanticsLabel('Toggle text chat'));
    await tester.pump();
    expect(container.read(voiceChatPaneVisibleProvider), isFalse);
  });

  for (final kind in ['text', 'dm']) {
    testWidgets('a $kind canvas has no chat toggle', (tester) async {
      await _pump(tester, _channel(kind: kind));
      expect(find.bySemanticsLabel('Toggle text chat'), findsNothing);
    });
  }

  testWidgets(
    'a message that arrived while closed lights the dot, opening hides it',
    (tester) async {
      final container = await _pump(tester, _channel(cursor: 4, lastRead: 2));
      expect(find.byKey(canvasChatUnreadKey), findsOneWidget);
      expect(
        find.bySemanticsLabel('Toggle text chat, new messages'),
        findsOneWidget,
      );

      await tester.tap(find.bySemanticsLabel('Toggle text chat, new messages'));
      await tester.pump();
      expect(container.read(voiceChatPaneVisibleProvider), isTrue);
      expect(find.byKey(canvasChatUnreadKey), findsNothing);
    },
  );

  testWidgets('a read channel shows no dot', (tester) async {
    await _pump(tester, _channel(cursor: 4, lastRead: 4));
    expect(find.byKey(canvasChatUnreadKey), findsNothing);
  });

  testWidgets('a mention counts as unread too', (tester) async {
    await _pump(tester, _channel(cursor: 4, lastRead: 2, mentioned: 3));
    expect(find.byKey(canvasChatUnreadKey), findsOneWidget);
  });

  testWidgets(
    'where the pane cannot dock the toggle sheets the chat and leaves the pane state alone',
    (tester) async {
      final container = await _pump(tester, _channel(), width: 700);
      expect(
        canvasChatDocks(
          tester.element(find.byWidgetPredicate((w) => w is Scaffold)),
        ),
        isFalse,
      );

      await tester.tap(find.bySemanticsLabel('Toggle text chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(container.read(voiceChatPaneVisibleProvider), isFalse);
      expect(find.bySemanticsLabel('Text chat'), findsOneWidget);
    },
  );

  group('at phone width the chat lives in the header overflow', () {
    Future<void> pumpOverflow(
      WidgetTester tester,
      Channel channel, {
      String? chatChannelId = 'c1',
    }) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          channelByIdProvider(
            'c1',
          ).overrideWith((ref) => Stream.value(channel)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: CanvasOverflowMenu(
                  canDraw: true,
                  onToggleFullscreen: () {},
                  canManage: false,
                  onClear: () async {},
                  selection: ValueNotifier(null),
                  onBringToFront: (_) {},
                  onSendToBack: (_) {},
                  onDeleteSelected: (_) {},
                  activityLogOpen: false,
                  onToggleActivityLog: () {},
                  tool: CanvasTool.pan,
                  shapeKind: CanvasShapeKind.rectangle,
                  onShapeKindChanged: (_) {},
                  hasSelfBubble: false,
                  selfBubbleHidden: false,
                  onToggleSelfBubbleHidden: () {},
                  hiddenTiles: const [],
                  onShowTile: (_) {},
                  opensBelow: true,
                  chatChannelId: chatChannelId,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a waiting message dots the trigger and the row says so', (
      tester,
    ) async {
      await pumpOverflow(tester, _channel(cursor: 3, lastRead: 1));
      expect(find.byKey(canvasChatUnreadKey), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Text chat, new messages'), findsOneWidget);

      await tester.tap(find.text('Text chat, new messages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.bySemanticsLabel('Text chat'), findsOneWidget);
    });

    testWidgets('a DM canvas, or no chat channel, adds no row', (tester) async {
      await pumpOverflow(tester, _channel(kind: 'dm'));
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Text chat'), findsNothing);
      expect(find.byKey(canvasChatUnreadKey), findsNothing);
    });

    testWidgets('without a chat channel there is no row', (tester) async {
      await pumpOverflow(tester, _channel(), chatChannelId: null);
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Text chat'), findsNothing);
    });
  });
}
