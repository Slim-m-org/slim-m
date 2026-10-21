// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal view in the app: the pill says which view this is and
/// switches it, a personal tile move is never sent to the server, and the
/// rects the canvas paints follow the view. Decision 0082.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_media_slot_sync.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_geometry.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_zoom_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _shared = Rect.fromLTWH(100, 100, 360, 203);
const _own = Rect.fromLTWH(900, 500, 360, 203);

class _Rig {
  _Rig() {
    document
      ..setBoard(canvasBoard)
      ..setViewport(const Size(1280, 720));
    tiles.applyServer(
      'screen:a',
      rect: _shared,
      locked: false,
      sentToBack: false,
    );
  }

  final document = CanvasDocument();
  final tiles = CanvasPresenceTileOverrides()..board = canvasBoard;
  late final mode = CanvasViewMode(document: document, tiles: tiles);
  final requests = <http.Request>[];

  CanvasMediaSlotSync get sync => CanvasMediaSlotSync(
    channelId: 'c1',
    overrides: tiles,
    client: testApi(
      (request) async {
        requests.add(request);
        return http.Response(
          '{"kind":"screen","user_id":"a","x":0,"y":0,"w":1,"h":1,'
          '"locked":false,"sent_to_back":false,"updated_at":1}',
          200,
          headers: {'content-type': 'application/json'},
        );
      },
      session: api.SessionStore(
        tokens: const api.TokenPair(
          userId: 'me',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
    ),
  );

  void dispose() {
    mode.dispose();
    tiles.dispose();
    document.dispose();
  }
}

Widget _wrap(Rig rig) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: SizedBox(
        width: 600,
        height: 400,
        child: Stack(
          children: [
            CanvasZoomIndicator(
              document: rig.document,
              tokens: AppTokens.light,
              viewMode: rig.mode,
              onFit: () {},
              onBringIn: () {},
            ),
          ],
        ),
      ),
    ),
  ),
);

typedef Rig = _Rig;

void main() {
  test('painted rects are the shared ones until the personal view is on', () {
    final rig = Rig();
    addTearDown(rig.dispose);
    const me = VoiceParticipant(
      identity: 'a',
      name: 'a',
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: true,
    );
    rig.tiles.setRect('screen:a', _own);
    rig.mode.showShared();
    Rect painted() => presenceOnCanvasRects(
      keys: const {'screen:a'},
      layout: const CanvasPresenceLayout(),
      overrides: rig.tiles,
      byIdentity: const {'a': me},
      hideSelfCamera: false,
    )['screen:a']!;

    expect(painted(), _own);
    rig.mode.showPersonal();
    rig.tiles.setRect('screen:a', const Rect.fromLTWH(10, 700, 360, 203));
    expect(painted(), const Rect.fromLTWH(10, 700, 360, 203));
    rig.mode.showShared();
    expect(painted(), _own);
  });
  testWidgets('the pill names the view and a tap switches it', (tester) async {
    final rig = Rig();
    addTearDown(rig.dispose);
    await tester.pumpWidget(_wrap(rig));

    expect(find.text('Shared view'), findsOneWidget);
    expect(rig.mode.personal, isFalse);

    await tester.tap(find.text('Shared view'));
    await tester.pump();

    expect(find.text('Personal view'), findsOneWidget);
    expect(rig.mode.personal, isTrue);

    await tester.tap(find.text('Personal view'));
    await tester.pump();
    expect(find.text('Shared view'), findsOneWidget);
    expect(rig.document.isFitted, isTrue);
  });

  test('a personal tile move is not sent to the server', () async {
    final rig = Rig();
    addTearDown(rig.dispose);
    rig.mode.showPersonal();
    rig.tiles.setRect('screen:a', _own);

    await rig.sync.commit('screen:a', _own);

    expect(rig.requests, isEmpty);
  });

  test('a shared tile move still is', () async {
    final rig = Rig();
    addTearDown(rig.dispose);
    rig.tiles.setRect('screen:a', _own);

    await rig.sync.commit('screen:a', _own);

    expect(rig.requests, hasLength(1));
  });

  testWidgets(
    'the reset action appears with a layout, names itself and resets',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = Rig();
      addTearDown(rig.dispose);
      await tester.pumpWidget(_wrap(rig));

      expect(find.byTooltip('Reset my layout'), findsNothing);

      rig.mode.showPersonal();
      rig.tiles.setRect('screen:a', _own);
      await tester.pump();

      expect(find.byTooltip('Reset my layout'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Reset my layout, return to the shared view'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Reset my layout'));
      await tester.pump();

      expect(rig.mode.personal, isFalse);
      expect(rig.tiles.personalPlaces, isEmpty);
      expect(find.byTooltip('Reset my layout'), findsNothing);
      semantics.dispose();
    },
  );

  testWidgets('the reset action is reachable by keyboard', (tester) async {
    final rig = Rig();
    addTearDown(rig.dispose);
    rig.mode.showPersonal();
    await tester.pumpWidget(_wrap(rig));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(rig.mode.hasLayout, isFalse);
  });
}
