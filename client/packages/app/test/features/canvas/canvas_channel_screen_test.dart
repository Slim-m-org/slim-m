// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A canvas channel's route is its board, with the chat beside it when asked and its own open state per channel.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_channel_chat_open.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/routing/breakpoints.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../settings/home_shell_harness.dart';

const _chatToggle = 'Toggle text chat';

Future<({ProviderContainer container, SlimmDatabase db})> _pump(
  WidgetTester tester, {
  required double width,
  List<api.Channel>? channels,
  String location = '/channels/c1',
}) async {
  final s = setup(httpClient: quietClient(), signedIn: true);
  await MessageStore(s.db).upsertChannels(
    channels ??
        const [
          api.Channel(id: 'c1', name: 'designs', kind: 'canvas', createdAt: 0),
        ],
  );
  await pumpAtWidth(tester, s.container, width, location: location);
  return s;
}

void _go(WidgetTester tester, String location) =>
    GoRouter.of(tester.element(_of<HomeShell>())).go(location);

double _boardWidth(WidgetTester tester) =>
    tester.getSize(_of<CanvasSurface>()).width;

/// A widget located by its type through a predicate, the repo's way past the find.byType ceiling.
Finder _of<T extends Widget>() => find.byWidgetPredicate((w) => w is T);

void main() {
  testWidgets('a canvas channel route is its board with no provider set', (
    tester,
  ) async {
    final s = await _pump(tester, width: 1400);

    expect(s.container.read(canvasOpenProvider), isNull);
    final bar = tester.getRect(_of<CanvasBar>());
    final board = tester.getRect(_of<CanvasSurface>());
    expect(board.width, greaterThan(0));
    expect(board.top, greaterThanOrEqualTo(bar.bottom));
    await teardown(tester, s.container, s.db);
  });

  testWidgets('switching away and back keeps it the board', (tester) async {
    final s = await _pump(
      tester,
      width: 1400,
      channels: const [
        api.Channel(id: 'c1', name: 'designs', kind: 'canvas', createdAt: 0),
        api.Channel(id: 'c2', name: 'general', kind: 'text', createdAt: 0),
      ],
    );

    _go(tester, '/channels/c2');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_of<CanvasPane>(), findsNothing);

    _go(tester, '/channels/c1');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_of<CanvasPane>(), findsOneWidget);
    expect(_of<CanvasBar>(), findsOneWidget);
    expect(s.container.read(canvasOpenProvider), isNull);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('the provider does not open a board on a channel without one', (
    tester,
  ) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels(const [
      api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    s.container.read(canvasOpenProvider.notifier).state = 'c1';
    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

    expect(_of<CanvasSurface>(), findsNothing);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('a voice canvas turned off while open lands on the call stage', (
    tester,
  ) async {
    final s = await _pump(
      tester,
      width: 1400,
      channels: const [
        api.Channel(id: 'c1', name: 'room', kind: 'voice', createdAt: 0),
      ],
    );
    s.container.read(canvasOpenProvider.notifier).state = 'c1';
    await tester.pump(const Duration(milliseconds: 400));
    expect(_of<CanvasSurface>(), findsOneWidget);

    await MessageStore(s.db).upsertChannels(const [
      api.Channel(
        id: 'c1',
        name: 'room',
        kind: 'voice',
        createdAt: 0,
        canvasEnabled: false,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 400));

    expect(_of<CanvasSurface>(), findsNothing);
    expect(
      find.text('The canvas was turned off for this channel.'),
      findsOneWidget,
    );
    expect(s.container.read(canvasOpenProvider), isNull);
    await tester.pump(const Duration(seconds: 7));
    expect(
      find.text('The canvas was turned off for this channel.'),
      findsNothing,
    );
    await teardown(tester, s.container, s.db);
  });

  group('chat beside the board', () {
    testWidgets('docks at 1400, snapping the board narrower by the pane', (
      tester,
    ) async {
      final s = await _pump(tester, width: 1400);
      final before = _boardWidth(tester);

      await tester.tap(find.bySemanticsLabel(_chatToggle));
      await tester.pump(const Duration(milliseconds: 400));

      expect(before - _boardWidth(tester), kThreadPaneWidth);
      expect(s.container.read(canvasChannelChatOpenProvider('c1')), isTrue);
      expect(s.container.read(voiceChatPaneVisibleProvider), isFalse);
      await teardown(tester, s.container, s.db);
    });

    testWidgets('is a sheet where it does not fit, leaving the board whole', (
      tester,
    ) async {
      final s = await _pump(tester, width: 900);
      final before = _boardWidth(tester);

      await tester.tap(find.bySemanticsLabel(_chatToggle));
      await tester.pump(const Duration(milliseconds: 400));

      final chat = tester.getRect(_of<ChannelScreen>());
      final view = tester.view.physicalSize;
      expect(chat.height, lessThanOrEqualTo(view.height * 0.8));
      expect(chat.width, lessThanOrEqualTo(view.width));
      expect(_boardWidth(tester), before);
      expect(s.container.read(canvasChannelChatOpenProvider('c1')), isFalse);
      await teardown(tester, s.container, s.db);
    });

    testWidgets('a route that opens chat shows the board with chat docked', (
      tester,
    ) async {
      final s = await _pump(
        tester,
        width: 1400,
        location: Routes.channel('c1', openChat: true),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(s.container.read(canvasChannelChatOpenProvider('c1')), isTrue);
      expect(_of<CanvasSurface>(), findsOneWidget);
      await teardown(tester, s.container, s.db);
    });
  });

  group('chat state', () {
    const channels = [
      api.Channel(id: 'c1', name: 'designs', kind: 'canvas', createdAt: 0),
      api.Channel(id: 'c2', name: 'sketches', kind: 'canvas', createdAt: 0),
      api.Channel(id: 'v1', name: 'room', kind: 'voice', createdAt: 0),
    ];

    testWidgets('a voice channel opened chat does not open a canvas channel', (
      tester,
    ) async {
      final s = await _pump(tester, width: 1400, channels: channels);
      final closed = _boardWidth(tester);

      s.container.read(voiceChatPaneVisibleProvider.notifier).state = true;
      _go(tester, '/channels/c2');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(_boardWidth(tester), closed);
      expect(s.container.read(canvasChannelChatOpenProvider('c2')), isFalse);
      expect(s.container.read(voiceChatPaneVisibleProvider), isTrue);
      expect(s.container.read(callDetailsOpenProvider), isFalse);
      await teardown(tester, s.container, s.db);
    });

    testWidgets('each canvas channel keeps its own, voice state untouched', (
      tester,
    ) async {
      final s = await _pump(tester, width: 1400, channels: channels);
      await tester.tap(find.bySemanticsLabel(_chatToggle));
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.container.read(canvasChannelChatOpenProvider('c1')), isTrue);

      _go(tester, '/channels/c2');
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.container.read(canvasChannelChatOpenProvider('c2')), isFalse);

      _go(tester, '/channels/c1');
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.container.read(canvasChannelChatOpenProvider('c1')), isTrue);
      expect(s.container.read(voiceChatPaneVisibleProvider), isFalse);
      expect(s.container.read(callDetailsOpenProvider), isFalse);
      await teardown(tester, s.container, s.db);
    });
  });

  testWidgets('a phone leaves a canvas channel by its back button, with no '
      'close', (tester) async {
    final s = await _pump(tester, width: 390);

    expect(find.bySemanticsLabel('Back to channels'), findsOneWidget);
    expect(find.bySemanticsLabel('Close canvas'), findsNothing);
    final back = tester.getRect(find.bySemanticsLabel('Back to channels'));
    final bar = tester.getRect(_of<CanvasBar>());
    expect(back.left, lessThan(bar.left + 64));
    expect(back.height, greaterThanOrEqualTo(44));
    await teardown(tester, s.container, s.db);
  });
}
