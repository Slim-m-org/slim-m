// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A floating dock at the viewport's foot is an inset for fitting the board,
/// not for painting: the fitted board sits above it (C-122).
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  const board = Rect.fromLTWH(0, 0, 1600, 900);
  const viewport = Size(1600, 900);

  test('the fitted board ends above the dock', () {
    final document = CanvasDocument()
      ..setViewport(viewport)
      ..setBoard(board);
    addTearDown(document.dispose);

    document.setBottomInset(120);

    final camera = document.camera;
    final boardBottomOnScreen = (board.bottom - camera.y) * camera.zoom;
    expect(
        boardBottomOnScreen, lessThanOrEqualTo(viewport.height - 120 + 1e-6));
    expect(document.isFitted, isTrue);
  });

  test('the whole viewport is still painted under the dock', () {
    final document = CanvasDocument()
      ..setViewport(viewport)
      ..setBoard(board)
      ..setBottomInset(120);
    addTearDown(document.dispose);

    final view = document.worldView;
    expect(view.height * document.camera.zoom, closeTo(viewport.height, 1e-6));
  });

  test('a zero inset fits the board to the whole viewport again', () {
    final document = CanvasDocument()
      ..setViewport(viewport)
      ..setBoard(board)
      ..setBottomInset(120)
      ..setBottomInset(0);
    addTearDown(document.dispose);

    expect(document.camera.zoom, closeTo(1, 1e-9));
  });
}
