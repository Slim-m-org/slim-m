// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rules decision 0081 sets for a tile in full screen: keys, announcements, following, summons and the corner chip.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

class _Voice extends VoiceController {
  _Voice(super.ref, VoiceState initial) : super(session: FakeSession()) {
    state = initial;
  }
}

VoiceParticipant _sharer(String id, String name) => VoiceParticipant(
  identity: id,
  name: name,
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
  isCameraOn: false,
);

const _ada = 'screen:user-ada';
const _bob = 'screen:user-bob';
const _expandLabel = 'Show this tile full screen';
const _view = Rect.fromLTWH(960, 540, 480, 270);

class _Rig {
  _Rig(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;
  TestGesture? _mouse;

  CanvasEngine get engine =>
      container.read(canvasEngineProvider('c1').notifier);
  CanvasViewRelay get relay => engine.viewRelay;
  CanvasDocument get document => engine.document;
  String? get focused => container.read(canvasFocusedTileProvider)?.tileKey;
  bool get fullscreen => container.read(canvasFullscreenProvider) == 'c1';

  Finder expandButton(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.bySemanticsLabel(_expandLabel),
  );

  Future<void> hover(String key) async {
    final center = tester.getCenter(find.byKey(ValueKey(key)));
    final mouse = _mouse;
    if (mouse == null) {
      final created = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(created.removePointer);
      await created.addPointer(location: center);
      _mouse = created;
    } else {
      await mouse.moveTo(center);
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> enter(String key) async {
    await hover(key);
    await tester.tap(expandButton(key));
    await tester.pumpAndSettle();
  }

  Future<void> settleGlide() async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> followedShows(String? tile) async {
    relay.applyRemote('user-ada', _view, summon: false, tile: tile);
    await tester.pumpAndSettle();
  }
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  bool board = false,
}) async {
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => _Voice(
          ref,
          VoiceState(
            channelId: 'c1',
            state: VoiceSessionState.connected,
            participants: [
              _sharer('user-ada', 'Ada'),
              _sharer('user-bob', 'Bob'),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasPane(tester, container, board: board, tool: null);
  await tester.pumpAndSettle();
  return _Rig(tester, container);
}

List<String> _recordAnnouncements(WidgetTester tester) {
  final heard = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (message) async {
      if (message is Map && message['type'] == 'announce') {
        final data = message['data'] as Map?;
        if (data?['message'] is String) heard.add(data!['message'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return heard;
}

void _expectCamera(Camera actual, Camera expected, {String? reason}) {
  expect(actual.x, closeTo(expected.x, 1e-6), reason: reason);
  expect(actual.y, closeTo(expected.y, 1e-6), reason: reason);
  expect(actual.zoom, closeTo(expected.zoom, 1e-9), reason: reason);
}

void main() {
  testWidgets('Escape and F both leave full screen', (tester) async {
    final rig = await _pump(tester);
    for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.keyF]) {
      await rig.enter(_ada);
      expect(rig.focused, _ada);
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(rig.focused, isNull, reason: '$key');
      expect(rig.fullscreen, isFalse, reason: '$key');
    }
  });

  testWidgets('F on a tile control opens that tile full screen', (
    tester,
  ) async {
    final rig = await _pump(tester);
    await rig.hover(_ada);
    final node = Focus.of(
      tester.element(
        find
            .descendant(of: rig.expandButton(_ada), matching: find.byType(Icon))
            .first,
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(rig.focused, _ada);
  });

  testWidgets('entering and leaving full screen are announced', (tester) async {
    final heard = _recordAnnouncements(tester);
    final rig = await _pump(tester);
    await rig.enter(_ada);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(heard, ["Full screen, Ada's screen", 'Exited full screen']);
  });

  testWidgets('following someone in full screen opens the same tile, and '
      'their leaving takes you out', (tester) async {
    final rig = await _pump(tester, board: true);
    rig.relay.follow('user-ada');
    await rig.followedShows(_ada);
    await rig.settleGlide();

    expect(rig.focused, _ada);
    expect(rig.fullscreen, isTrue);
    expect(
      rig.relay.following.value,
      'user-ada',
      reason: 'the fit is not a pan',
    );

    await rig.followedShows(null);
    expect(rig.focused, isNull);
    expect(rig.fullscreen, isFalse);
    expect(rig.relay.following.value, 'user-ada');
  });

  testWidgets('following someone who is already full screen opens it at once', (
    tester,
  ) async {
    final rig = await _pump(tester, board: true);
    rig.relay.applyRemote('user-ada', _view, summon: false, tile: _ada);
    expect(rig.focused, isNull, reason: 'not following yet');
    rig.relay.follow('user-ada');
    await tester.pumpAndSettle();
    expect(rig.focused, _ada);
  });

  testWidgets('a second full screen request refits to the new tile', (
    tester,
  ) async {
    final rig = await _pump(tester, board: true);
    rig.relay.follow('user-ada');
    await rig.followedShows(_ada);
    final first = rig.document.camera;

    await rig.followedShows(_bob);

    expect(rig.focused, _bob);
    expect(rig.document.camera, isNot(first));
  });

  testWidgets('stopping the follow leaves you in full screen where you are', (
    tester,
  ) async {
    final rig = await _pump(tester, board: true);
    rig.relay.follow('user-ada');
    await rig.followedShows(_ada);

    rig.relay.stopFollowing();
    await tester.pumpAndSettle();

    expect(rig.focused, _ada);
    await rig.followedShows(null);
    expect(rig.focused, _ada, reason: 'no longer following');
  });

  testWidgets('a share the viewer cannot see does not open full screen', (
    tester,
  ) async {
    final rig = await _pump(tester, board: true);
    rig.relay.follow('user-ada');
    await rig.followedShows('screen:user-nobody');
    expect(rig.focused, isNull);
  });

  group('a summon is a request', () {
    Future<_Rig> pumpSummoned(WidgetTester tester, {Size? size}) async {
      final rig = await _pump(
        tester,
        board: true,
        size: size ?? const Size(1280, 800),
      );
      rig.relay.applyRemote('user-ada', _view, summon: true);
      await tester.pump();
      return rig;
    }

    testWidgets('nothing moves, and the person can accept or decline', (
      tester,
    ) async {
      final rig = await _pump(tester, board: true);
      final before = rig.document.camera;
      rig.relay.applyRemote('user-ada', _view, summon: true);
      await tester.pump();

      expect(find.text('Ada wants to bring you to their view'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);
      expect(rig.document.camera, before);
    });

    testWidgets('declining leaves the view alone and clears the prompt', (
      tester,
    ) async {
      final rig = await pumpSummoned(tester);
      final before = rig.document.camera;
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      expect(find.text('Accept'), findsNothing);
      expect(rig.document.camera, before);
    });

    testWidgets('accepting moves to the summoner view', (tester) async {
      final rig = await pumpSummoned(tester);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      await rig.settleGlide();
      expect(find.text('Accept'), findsNothing);
      _expectCamera(
        rig.document.camera,
        cameraForBoardView(_view, rig.document.board!, rig.document.viewport),
      );
    });

    testWidgets('an unanswered request lapses quietly', (tester) async {
      final rig = await pumpSummoned(tester);
      final before = rig.document.camera;
      await tester.pump(summonRequestTimeout + const Duration(seconds: 1));
      expect(find.text('Accept'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(rig.document.camera, before);
    });

    testWidgets('accepting in full screen leaves it first, then moves', (
      tester,
    ) async {
      final rig = await _pump(tester, board: true);
      rig.container.read(canvasFullscreenProvider.notifier).state = 'c1';
      rig.container.read(canvasFocusedTileProvider.notifier).state = (
        channelId: 'c1',
        tileKey: _ada,
      );
      await tester.pumpAndSettle();
      expect(rig.fullscreen, isTrue);
      rig.relay.applyRemote('user-bob', _view, summon: true);
      await tester.pump();

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      await rig.settleGlide();

      expect(rig.fullscreen, isFalse);
      expect(rig.focused, isNull);
      _expectCamera(
        rig.document.camera,
        cameraForBoardView(_view, rig.document.board!, rig.document.viewport),
        reason: 'the restore of the pre-full-screen camera must not win',
      );
    });
  });

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    testWidgets('the full screen name chip clears the zoom pill at '
        '${size.width.toInt()}', (tester) async {
      final rig = await _pump(tester, size: size);
      await rig.enter(_ada);
      final chip = tester.getRect(find.text("Ada's screen"));
      final pill = tester.getRect(find.byTooltip('Fit view'));
      expect(chip.overlaps(pill), isFalse, reason: '$chip vs $pill');
    });
  }
}
