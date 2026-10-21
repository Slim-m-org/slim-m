// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera or share the local person starts appears centred where they are looking; nobody else's view moves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_spawn.dart';
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

CanvasDocument _document() => CanvasDocument()
  ..setBoard(const Rect.fromLTWH(0, 0, 1920, 1080))
  ..setViewport(const Size(600, 400))
  ..setCamera(const Camera(x: 900, y: 500, zoom: 1));

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

void main() {
  testWidgets('a share the local person starts is centred in their view and '
      'committed for everyone', (tester) async {
    final document = _document();
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(document.dispose);
    addTearDown(overrides.dispose);
    final commits = <String, Rect>{};
    await _pump(tester, document, overrides, [
      _me(),
      _other,
    ], (k, r) => commits[k] = r);
    expect(commits, isEmpty);

    await _pump(tester, document, overrides, [
      _me(screen: true),
      _other,
    ], (k, r) => commits[k] = r);
    await tester.pump();

    final rect = commits['screen:me']!;
    expect(rect.center, document.worldView.center);
    expect(overrides.stateFor('screen:me').rect, rect);
  });

  testWidgets('a share already live when the canvas opens is left where it '
      'is', (tester) async {
    final document = _document();
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(document.dispose);
    addTearDown(overrides.dispose);
    final commits = <String, Rect>{};
    await _pump(tester, document, overrides, [
      _me(screen: true),
    ], (k, r) => commits[k] = r);
    await tester.pump();
    expect(commits, isEmpty);
  });

  testWidgets("someone else's share does not move this person's tiles", (
    tester,
  ) async {
    final document = _document();
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(document.dispose);
    addTearDown(overrides.dispose);
    final commits = <String, Rect>{};
    await _pump(tester, document, overrides, [
      _me(),
      _other,
    ], (k, r) => commits[k] = r);
    await _pump(tester, document, overrides, [
      _me(),
      const VoiceParticipant(
        identity: 'other',
        name: 'Other',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: true,
      ),
    ], (k, r) => commits[k] = r);
    await tester.pump();
    expect(commits, isEmpty);
  });

  test('with no viewport the tile goes to the centre of the board', () {
    final document = CanvasDocument()
      ..setBoard(const Rect.fromLTWH(0, 0, 1920, 1080));
    addTearDown(document.dispose);
    final rect = presenceSpawnRect('camera:me', document)!;
    expect(rect.center, const Offset(960, 540));
  });

  test('a view at the board edge keeps the tile inside the board', () {
    final document = _document()
      ..setCamera(const Camera(x: 1500, y: 700, zoom: 1));
    addTearDown(document.dispose);
    final rect = presenceSpawnRect('screen:me', document)!;
    expect(const Rect.fromLTWH(0, 0, 1920, 1080).contains(rect.topLeft), true);
    expect(rect.right, lessThanOrEqualTo(1920));
    expect(rect.bottom, lessThanOrEqualTo(1080));
  });

  test('a tile already at the centre is nudged off', () {
    final document = _document();
    addTearDown(document.dispose);
    final first = presenceSpawnRect('camera:me', document)!;
    final second = presenceSpawnRect('camera:me', document, taken: [first])!;
    expect(second.overlaps(first), isFalse);
    expect(second.topLeft, isNot(first.topLeft));
  });
}
