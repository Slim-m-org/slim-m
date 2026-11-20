// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An animated custom emoji stamped on a share plays, as it does in a message.
///
/// The owner, 2026-11-20, in a call over someone's share: "stamp emojis not
/// animated". Only a picture stamp ever played; a custom emoji that is a GIF
/// showed its baked still frame.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/stamp_view.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_images.dart';

/// Two 1x1 frames, red then blue, 100ms apart, looping forever; a fresh copy each time, since the image cache keys a picture by its bytes.
Uint8List _twoFrameGif() => base64Decode(
  'R0lGODlhAQABAIAAAP8AAAAA/yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAAC'
  'AkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw==',
);

const _partyId = '01a0459d-3038-73f0-b530-73a38681d4ae';

/// The distinct frames drawn over [steps] rounds that give the real-time decode and the fake-time frame timer a turn each.
Future<Set<int>> _framesDrawn(WidgetTester tester, {int steps = 12}) async {
  final frames = <int>{};
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    for (final drawn in tester.allRenderObjects.whereType<RenderImage>()) {
      if (drawn.image != null) frames.add(drawn.image.hashCode);
    }
  }
  return frames;
}

Future<void> _pumpStamp(
  WidgetTester tester,
  StampContent content, {
  required Uint8List emojiBytes,
}) async {
  final cache = StampImageCache(
    fetchStill: (_) => throw UnimplementedError(),
    fetchOriginal: (_) => throw UnimplementedError(),
    customEmojiBytes: (_) async => emojiBytes,
    customIndex: () => const {'party': _partyId},
  );
  addTearDown(cache.clear);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [stampImageCacheProvider.overrideWithValue(cache)],
      child: MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 64,
            child: StampView(content: content),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('an animated custom emoji stamp plays its frames', (
    tester,
  ) async {
    await _pumpStamp(
      tester,
      const EmojiStamp(_partyId),
      emojiBytes: _twoFrameGif(),
    );
    expect(await _framesDrawn(tester), hasLength(greaterThan(1)));
  });

  testWidgets('a shortcode names the same emoji and plays too', (tester) async {
    await _pumpStamp(
      tester,
      const EmojiStamp(':party:'),
      emojiBytes: _twoFrameGif(),
    );
    expect(await _framesDrawn(tester), hasLength(greaterThan(1)));
  });
}
