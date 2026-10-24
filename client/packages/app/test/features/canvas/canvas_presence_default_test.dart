// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tile nobody has moved sits at a spot that depends only on which tiles exist, so every viewer agrees.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'presence_stack.dart';

VoiceParticipant _me({bool camera = false, bool screen = false}) =>
    VoiceParticipant(
      identity: 'me',
      name: 'Me',
      isSpeaking: false,
      isMuted: false,
      isLocal: true,
      isScreenSharing: screen,
      isCameraOn: camera,
    );

const _other = VoiceParticipant(
  identity: 'other',
  name: 'Other',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

Future<void> _pump(
  WidgetTester tester,
  CanvasDocument document,
  CanvasPresenceTileOverrides overrides,
  List<VoiceParticipant> participants,
  void Function(String, Rect) onCommit,
) => tester.pumpWidget(
  ProviderScope(
    child: MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 400,
          child: PresenceStack(
            document: document,
            participants: participants,
            cameraViewFor: (_) => const SizedBox(),
            screenShareViewFor: (_) => const SizedBox(),
            overrides: overrides,
            onCommit: onCommit,
          ),
        ),
      ),
    ),
  ),
);

Map<String, Rect> _spots(
  List<String> keys, {
  Size window = const Size(600, 400),
  double dock = 0,
  Map<String, Rect> slots = const {},
}) {
  final document = CanvasDocument()
    ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
    ..setViewport(window)
    ..setBottomInset(dock);
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(document.dispose);
  addTearDown(overrides.dispose);
  for (final e in slots.entries) {
    overrides.applyServer(
      e.key,
      rect: e.value,
      locked: false,
      sentToBack: false,
    );
  }
  final people = <VoiceParticipant>[];
  for (final key in keys) {
    final id = key.split(':').last;
    final screen = key.startsWith('screen');
    final i = people.indexWhere((p) => p.identity == id);
    final old = i < 0 ? null : people.removeAt(i);
    people.add(
      VoiceParticipant(
        identity: id,
        name: id,
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: screen || (old?.isScreenSharing ?? false),
        isCameraOn: !screen || (old?.isCameraOn ?? false),
      ),
    );
  }
  return CanvasPresenceFrameResolver()
      .resolve(
        participants: people,
        document: document,
        overrides: overrides,
        layout: const CanvasPresenceLayout(),
        hideSelfCamera: false,
      )
      .onCanvas;
}

void main() {
  testWidgets(
    'starting a share writes no slot: its spot is the shared default',
    (tester) async {
      final document = CanvasDocument()
        ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
        ..setViewport(const Size(600, 400));
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(document.dispose);
      addTearDown(overrides.dispose);
      final commits = <String, Rect>{};
      await _pump(tester, document, overrides, [
        _me(),
        _other,
      ], (k, r) => commits[k] = r);
      await _pump(tester, document, overrides, [
        _me(screen: true),
        _other,
      ], (k, r) => commits[k] = r);
      await tester.pump();
      expect(commits, isEmpty);
      expect(overrides.stateFor('screen:me').rect, isNull);
    },
  );

  for (var n = 1; n <= 8; n++) {
    test(
      '$n screen shares sit apart, the same on any window and join order',
      () {
        final keys = [for (var i = 0; i < n; i++) 'screen:u$i'];
        final a = _spots(keys);
        final b = _spots(keys.reversed.toList(), window: const Size(1400, 900));
        expect(b, a);
        final rects = a.values.toList();
        for (var i = 0; i < rects.length; i++) {
          for (var j = i + 1; j < rects.length; j++) {
            expect(rects[i].overlaps(rects[j]), isFalse, reason: '$i vs $j');
          }
        }
      },
    );
  }

  test('four shares are one row on the shared area', () {
    final spots = _spots([for (var i = 0; i < 4; i++) 'screen:u$i']);
    expect({for (final r in spots.values) r.top}.length, 1);
  });

  test('a camera and a screen from one person sit apart', () {
    final spots = _spots(['camera:u1', 'screen:u1', 'camera:u2']);
    final r = spots.values.toList();
    expect(r[0].overlaps(r[1]), isFalse);
    expect(r[1].overlaps(r[2]), isFalse);
    expect(r[0].overlaps(r[2]), isFalse);
  });

  test('a late joiner who sees the same tiles computes the same spots', () {
    final keys = [for (var i = 0; i < 4; i++) 'screen:u$i'];
    expect(_spots(keys.reversed.toList()), _spots(keys));
  });

  test('a moved tile keeps its place when more tiles arrive', () {
    const moved = Rect.fromLTWH(1000, 700, 360, 203);
    final before = _spots(
      ['screen:u1', 'screen:u2'],
      slots: {'screen:u1': moved},
    );
    final after = _spots(
      ['screen:u1', 'screen:u2', 'screen:u3'],
      slots: {'screen:u1': moved},
    );
    expect(before['screen:u1'], moved);
    expect(after['screen:u1'], moved);
  });

  test('window width, height and dock change neither spot nor size', () {
    final keys = [
      for (var i = 0; i < 4; i++) 'screen:u$i',
      'camera:u0',
      'camera:u9',
    ];
    final reference = _spots(keys, window: const Size(1920, 1080));
    const windows = [
      Size(390, 844),
      Size(599, 700),
      Size(601, 700),
      Size(900, 557),
      Size(1280, 400),
      Size(1920, 1080),
    ];
    for (final window in windows) {
      for (final dock in [0.0, 90.0, 160.0]) {
        expect(
          _spots(keys, window: window, dock: dock),
          reference,
          reason: '$window dock $dock',
        );
      }
    }
  });
}
