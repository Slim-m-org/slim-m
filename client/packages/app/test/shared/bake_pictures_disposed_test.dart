// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every bake that records a picture to make an image disposes the picture,
/// rather than leaving it, and the source image it holds, for a collection.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/call_overlay_avatar_render.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_bake.dart';
import 'package:slimm_app/src/features/voice/providers/lounge_canvas_glow.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// The pictures created while [body] ran that it left undisposed.
Future<List<ui.Picture>> _leftBy(Future<void> Function() body) async {
  final recorded = <ui.Picture>[];
  void onEvent(ObjectEvent event) {
    final object = event.object;
    if (event is ObjectCreated && object is ui.Picture) recorded.add(object);
  }

  FlutterMemoryAllocations.instance.addListener(onEvent);
  try {
    await body();
  } finally {
    FlutterMemoryAllocations.instance.removeListener(onEvent);
  }
  expect(recorded, isNotEmpty, reason: 'the bake recorded a picture');
  return [
    for (final picture in recorded)
      if (!picture.debugDisposed) picture,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a stamp baked from an emoji', () async {
    final left = await _leftBy(
      () async => (await bakeEmojiGlyph('a', edge: 32)).dispose(),
    );
    expect(left, isEmpty);
  });

  test('a stamp baked from a picture', () async {
    final source = await createTestImage(width: 40, height: 20);
    addTearDown(source.dispose);
    final left = await _leftBy(
      () async => (await bakeScaled(source, edge: 16)).dispose(),
    );
    expect(left, isEmpty);
  });

  test('a call panel avatar', () async {
    final left = await _leftBy(
      () => renderOverlayAvatar(name: 'Riley', tintKey: 'u-7'),
    );
    expect(left, isEmpty);
  });

  test('a voice channel glow', () async {
    final document = CanvasDocument()..setBoard(canvasBoard);
    addTearDown(document.dispose);
    final left = await _leftBy(
      () async => (await paintLoungeGlow(document)).dispose(),
    );
    expect(left, isEmpty);
  });
}
