// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bitmaps inline emoji are drawn from: a failed load is tried again, the set is bounded, and another server starts empty.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_note_emoji_images.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/providers.dart';

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

final _server = StateProvider<Uri>((ref) => Uri.parse('http://one.test'));

class _Rig {
  _Rig(this.tester, {this.failFirst = 0});

  final WidgetTester tester;
  final int failFirst;
  final asked = <String>[];

  late final container = ProviderContainer(
    overrides: [
      serverUrlProvider.overrideWith((ref) => ref.watch(_server)),
      customEmojiImageProvider.overrideWith((ref, id) {
        ref.watch(_server);
        asked.add(id);
        if (asked.length <= failFirst) throw StateError('offline');
        return _png;
      }),
    ],
  );

  CanvasNoteEmojiImages get images =>
      container.read(canvasNoteEmojiImagesProvider.notifier);

  Future<void> decode([int ms = 150]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('a failed load is tried again after the backoff', (tester) async {
    final rig = _Rig(tester, failFirst: 1);
    addTearDown(rig.container.dispose);
    rig.container.listen(canvasNoteEmojiImagesProvider, (_, _) {});

    expect(rig.images.imageOf('e1'), isNull);
    await rig.decode();
    expect(rig.asked, hasLength(1));
    expect(rig.images.imageOf('e1'), isNull, reason: 'baseline: it failed');

    await tester.pump(canvasInlineEmojiRetryDelay);
    await rig.decode();

    expect(rig.asked, hasLength(2));
    expect(rig.images.imageOf('e1'), isNotNull);
  });

  testWidgets('another server starts with none of the first one', (
    tester,
  ) async {
    final rig = _Rig(tester);
    addTearDown(rig.container.dispose);
    rig.container.listen(canvasNoteEmojiImagesProvider, (_, _) {});
    rig.images.imageOf('e1');
    await rig.decode();
    expect(rig.container.read(canvasNoteEmojiImagesProvider), isNotEmpty);

    rig.container.read(_server.notifier).state = Uri.parse('http://two.test');

    expect(rig.container.read(canvasNoteEmojiImagesProvider), isEmpty);
    rig.images.imageOf('e1');
    await rig.decode();
    expect(rig.asked, ['e1', 'e1'], reason: 'asked of the new server again');
    await rig.decode(50);
    await tester.pump(const Duration(milliseconds: 10));
    rig.container.dispose();
  });

  testWidgets('the decoded set is bounded and keeps what was drawn last', (
    tester,
  ) async {
    final rig = _Rig(tester);
    addTearDown(rig.container.dispose);
    rig.container.listen(canvasNoteEmojiImagesProvider, (_, _) {});
    for (var i = 0; i < canvasInlineEmojiCacheLimit; i++) {
      rig.images.imageOf('e$i');
    }
    await rig.decode(2000);
    expect(
      rig.container.read(canvasNoteEmojiImagesProvider),
      hasLength(canvasInlineEmojiCacheLimit),
      reason: 'baseline: the set is full',
    );

    rig.images.imageOf('e0');
    rig.images.imageOf('extra');
    await rig.decode();

    final held = rig.container.read(canvasNoteEmojiImagesProvider);
    expect(held, hasLength(canvasInlineEmojiCacheLimit));
    expect(held.keys, containsAll(['e0', 'extra']));
    await rig.decode(50);
    await tester.pump(const Duration(milliseconds: 10));
    rig.container.dispose();
  });
}
