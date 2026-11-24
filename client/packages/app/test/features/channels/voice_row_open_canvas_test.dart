// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The owner: "no way to just enter a canvas in the context menu of a voice call".
/// A voice row's menu opens its canvas as a spectator, without joining, at every width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_open.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart'
    show callDetailsOpenProvider;
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

import '../settings/home_shell_harness.dart';
import '../../support/async_wait.dart';
import '../../support/menu_gestures.dart';
import '../voice/voice_controller_harness.dart' show FixedVoiceController;

const _voiceId = 'c-voice';
const _lobbyId = 'c-lobby';
const _textId = 'c-text';

Future<({ProviderContainer container, SlimmDatabase db, GoRouter router})>
_pump(WidgetTester tester, double width, {bool inCall = false}) async {
  final fixture = setup(
    signedIn: true,
    httpClient: quietClient(),
    extraOverrides: [
      if (inCall)
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(
            ref,
            const VoiceState(
              state: VoiceSessionState.connected,
              channelId: _voiceId,
            ),
          ),
        ),
    ],
  );
  final store = await fixture.container.read(storeProvider.future);
  await tester.runAsync(
    () => store.upsertChannels([
      const api.Channel(
        id: _voiceId,
        name: 'movie-room',
        kind: 'voice',
        createdAt: 0,
        position: 0,
      ),
      const api.Channel(
        id: _lobbyId,
        name: 'make-a-room',
        kind: 'voice',
        createdAt: 0,
        position: 1,
        createsRooms: true,
      ),
      const api.Channel(
        id: _textId,
        name: 'general',
        kind: 'text',
        createdAt: 0,
        position: 2,
      ),
    ]),
  );
  final router = testRouter('/channels');
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await pumpFrames(tester);
  return (container: fixture.container, db: fixture.db, router: router);
}

Future<void> _openMenu(WidgetTester tester, double width, String row) =>
    width < 600
    ? longPressMenu(tester, find.text(row).first)
    : rightClickMenu(tester, find.text(row).first);

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('Open canvas spectates a voice channel without joining at '
        '$width', (tester) async {
      final semantics = tester.ensureSemantics();
      final s = await _pump(tester, width);

      await _openMenu(tester, width, 'movie-room');
      expect(find.text('Open canvas'), findsOneWidget);
      expect(
        tester.getRect(find.text('Open canvas')).top,
        greaterThan(tester.getRect(find.text('Open chat')).top),
        reason: 'beside Open chat, under it',
      );
      expect(
        find.bySemanticsLabel('Open canvas'),
        findsWidgets,
        reason: 'reachable by a screen reader',
      );
      await tester.tap(find.text('Open canvas'));
      await pumpFrames(tester, frames: 20);

      expect(s.container.read(canvasOpenProvider), _voiceId);
      expect(s.container.read(voiceFlagsProvider).channelId, isNull);
      expect(
        s.router.routerDelegate.currentConfiguration.uri.path,
        '/channels/$_voiceId',
      );

      s.container.read(canvasOpenProvider.notifier).state = null;
      await pumpFrames(tester, frames: 20);
      expect(
        s.container.read(voiceFlagsProvider).channelId,
        isNull,
        reason: 'closing the canvas never joins either',
      );

      semantics.dispose();
      await teardown(tester, s.container, s.db);
    });
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('closing the canvas from inside its call leaves details '
        'closed at $width', (tester) async {
      final s = await _pump(tester, width, inCall: true);

      await _openMenu(tester, width, 'movie-room');
      await tester.tap(find.text('Open canvas'));
      await pumpFrames(tester, frames: 20);
      expect(s.container.read(canvasOpenProvider), _voiceId);

      s.container.read(canvasOpenProvider.notifier).state = null;
      await pumpFrames(tester, frames: 20);
      expect(s.container.read(callDetailsOpenProvider), isFalse);
      expect(find.text('Call details'), findsNothing);

      await teardown(tester, s.container, s.db);
    });
  }

  testWidgets('a lobby and a text channel offer no canvas', (tester) async {
    final s = await _pump(tester, 1280);

    await _openMenu(tester, 1280, 'make-a-room');
    expect(find.text('Open canvas'), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await pumpFrames(tester);

    await _openMenu(tester, 1280, 'general');
    expect(find.text('Open canvas'), findsNothing);

    await teardown(tester, s.container, s.db);
  });
}
