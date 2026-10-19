// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Untouched call tiles land in the same world place for every viewer once the
/// canvas is the shared board, whatever their window width.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_frame.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

VoiceParticipant _p(String id) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

Map<String, Rect> _rectsAt(Size window, {required bool board}) {
  final document = CanvasDocument();
  if (board) document.setBoard(canvasBoard);
  document.setViewport(window);
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(document.dispose);
  addTearDown(overrides.dispose);
  return CanvasPresenceFrameResolver()
      .resolve(
        participants: [for (var i = 0; i < 8; i++) _p('user$i')],
        document: document,
        overrides: overrides,
        layout: const CanvasPresenceLayout(),
        hideSelfCamera: false,
      )
      .onCanvas;
}

void main() {
  test('tiles sit at the same world rects on a phone, laptop and monitor', () {
    final phone = _rectsAt(const Size(390, 844), board: true);
    final laptop = _rectsAt(const Size(1280, 800), board: true);
    final monitor = _rectsAt(const Size(2560, 1440), board: true);

    expect(phone, isNotEmpty);
    expect(laptop, phone);
    expect(monitor, phone);
  });

  test('every default tile lies inside the board', () {
    for (final rect in _rectsAt(const Size(390, 844), board: true).values) {
      expect(canvasBoard.inflate(0.01).contains(rect.topLeft), isTrue);
      expect(canvasBoard.inflate(0.01).contains(rect.bottomRight), isTrue);
    }
  });

  test('without a board the layout still follows the window (as before)', () {
    final narrow = _rectsAt(const Size(390, 844), board: false);
    final wide = _rectsAt(const Size(2560, 1440), board: false);
    expect(narrow, isNot(wide));
  });
}
