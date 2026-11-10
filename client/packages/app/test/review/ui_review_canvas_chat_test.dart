// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's text chat opened from its canvas: a sheet over the canvas on a phone, docked beside it on a desktop, dark and light.
/// Rendered in the real shell, since the chat is the channel's own screen. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';

import '../features/voice/voice_snapshot_fixtures.dart';
import '../support/mid_flight_capture.dart';
import '../ui_snapshot_support.dart';
import 'review_support.dart';
import 'ui_review_canvas_rig.dart';

api.Message _chat(int seq, String author, String name, String content) =>
    api.Message(
      id: 'main-$seq',
      channelId: 'c-main',
      authorId: author,
      authorDisplayName: name,
      seq: seq,
      content: content,
      createdAt: 1753600000000 + seq * 60000,
      editedAt: null,
    );

/// What the voice channel's own chat holds: the logistics a call tends to produce.
final _voiceChat = [
  _chat(
    1,
    'user-ada',
    'Ada Lovelace',
    'Dropping the retro board link in a sec.',
  ),
  _chat(
    2,
    'user-nick',
    'Nick',
    'Sharing my screen now, can you see the canvas?',
  ),
  _chat(
    3,
    'user-ada',
    'Ada Lovelace',
    'Yes, and the follow chip works. Can we pin the notes under the heading before Friday so nobody has to hunt for them?',
  ),
  _chat(4, 'user-nick', 'Nick', 'Will do.'),
];

/// The shell on the fixture's voice channel with its canvas open and the call connected.
Future<void> _chatOverCanvas(
  WidgetTester tester, {
  required String viewport,
  required String theme,
  required String state,
  required Future<void> Function(WidgetTester tester) open,
}) async {
  tester.view.physicalSize = reviewCanvasViewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fixture = await fixtureContainer(
    messages: [...fixtureMessages, ..._voiceChat],
    extraOverrides: [
      canvasOpenProvider.overrideWith((ref) => 'c-main'),
      voiceControllerProvider.overrideWith(
        (ref) => SnapshotVoiceController(
          ref,
          connectedCallState.copyWith(
            connectedAt: DateTime.now().subtract(
              const Duration(minutes: 12, seconds: 41),
            ),
          ),
        ),
      ),
    ],
  );
  final router = fixtureRouter('/channels/c-main');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            snapshotThemes[theme]!.brightness,
            snapshotThemes[theme]!.tokens,
          ),
          routerConfig: router,
          builder: appChromeBuilder,
        ),
      ),
    ),
  );
  await tester.pump();
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  // The channel list comes off the drift stream, which needs real time to emit.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 150)),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await open(tester);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  final name = reviewName(
    'sheet-canvas-chat',
    state: state,
    viewport: viewport,
    theme: theme,
  );
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
  await teardownFixture(tester, fixture.container, fixture.db);
}

void main() {
  setUpAll(loadRealFonts);

  for (final theme in reviewThemes) {
    testWidgets('sheet-canvas-chat sheet phone $theme', (tester) async {
      await _chatOverCanvas(
        tester,
        viewport: 'phone',
        theme: theme,
        state: 'sheet',
        open: (t) async {
          await t.tap(find.byTooltip('More canvas actions').first);
          await t.pump();
          await t.pump(const Duration(milliseconds: 350));
          await t.tap(find.textContaining('Text chat').first);
          await t.pump();
        },
      );
    });

    testWidgets('sheet-canvas-chat docked desktop $theme', (tester) async {
      await _chatOverCanvas(
        tester,
        viewport: 'desktop',
        theme: theme,
        state: 'docked',
        open: (t) async {
          await t.tap(find.byTooltip('Text chat').first);
          await t.pump();
        },
      );
    });
  }
}
