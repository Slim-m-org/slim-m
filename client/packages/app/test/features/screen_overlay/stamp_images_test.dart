// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stamp's one bitmap, baked for real through dart:ui (decision 0121): 512
/// px on its longest side, its shape kept, held in memory only, and put on
/// the overlay runner once.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/overlay_stamp_images.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_frame.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_bake.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_images.dart';
import 'package:slimm_platform/platform.dart';

import 'overlay_rig.dart';
import 'stamp_frames.dart';

Future<Uint8List> _solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFD03030),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A runner whose putImage answers only when the test says.
class _SlowPuts extends FakeOverlay {
  final reply = Completer<bool>();

  @override
  Future<bool> putImage(String key, Uint8List png) => reply.future;
}

Future<(int, int)> _sizeOf(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final size = (image.width, image.height);
  image.dispose();
  codec.dispose();
  return size;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('baking', () {
    test('an emoji bakes to a 512 px square PNG', () async {
      final image = await bakeEmojiGlyph('\u{1F389}');
      final png = await encodeStampPng(image);
      image.dispose();
      expect(await _sizeOf(png), (512, 512));
    });

    test(
      'a wide picture keeps its shape with 512 px on its long side',
      () async {
        final cache = StampImageCache(
          fetchStill: (_) => _solidPng(800, 200),
          fetchOriginal: (_) => throw UnimplementedError(),
          customEmojiBytes: (_) => throw UnimplementedError(),
          customIndex: () => const {},
        );
        final png = await cache.png(const PictureStamp('wide'));
        expect(await _sizeOf(png), (512, 128));
      },
    );

    test('a small custom emoji is scaled up to the same edge', () async {
      final cache = StampImageCache(
        fetchStill: (_) => throw UnimplementedError(),
        fetchOriginal: (_) => throw UnimplementedError(),
        customEmojiBytes: (_) => _solidPng(64, 64),
        customIndex: () => const {'party': 'id-1'},
      );
      final png = await cache.png(const EmojiStamp(':party:'));
      expect(await _sizeOf(png), (512, 512));
    });
  });

  group('the cache', () {
    late List<String> fetched;
    late StampImageCache cache;

    setUp(() {
      fetched = [];
      cache = StampImageCache(
        fetchStill: (id) {
          fetched.add(id);
          return _solidPng(40, 40);
        },
        fetchOriginal: (id) async => Uint8List(stampAnimatedMaxBytes + 1),
        customEmojiBytes: (_) => throw UnimplementedError(),
        customIndex: () => const {},
      );
    });

    tearDown(() => cache.clear());

    test(
      'two asking at once fetch once, and a later ask fetches nothing',
      () async {
        await Future.wait([
          cache.load(const PictureStamp('a')),
          cache.load(const PictureStamp('a')),
        ]);
        await cache.load(const PictureStamp('a'));
        expect(fetched, ['a']);
        final copy = cache.peek(const PictureStamp('a'))!;
        expect(copy.width, 512);
        copy.dispose();
      },
    );

    test('it keeps 32 and lets the least recently used go', () async {
      for (var i = 0; i <= stampImagesKept; i++) {
        await cache.load(PictureStamp('p$i'));
      }
      expect(cache.holds(const PictureStamp('p0')), isFalse);
      expect(cache.holds(const PictureStamp('p$stampImagesKept')), isTrue);
    });

    test(
      'the call ending drops everything, and a load in flight is thrown away',
      () async {
        final slow = Completer<Uint8List>();
        final late = StampImageCache(
          fetchStill: (_) => slow.future,
          fetchOriginal: (_) => throw UnimplementedError(),
          customEmojiBytes: (_) => throw UnimplementedError(),
          customIndex: () => const {},
        );
        final load = late.load(const PictureStamp('a'));
        late.clear();
        slow.complete(await _solidPng(10, 10));
        await expectLater(load, throwsStateError);
        expect(late.holds(const PictureStamp('a')), isFalse);
      },
    );

    test('a GIF over 4 MiB never animates', () async {
      expect(await cache.original('big'), isNull);
    });
  });

  group('the overlay runner', () {
    test(
      'a picture is put once, the oldest dropped past 24, all forgotten on hide',
      () async {
        final overlay = FakeOverlay();
        final images = OverlayStampImages(overlay);
        Future<Uint8List> bake() async => Uint8List.fromList([1]);
        expect(await images.ensure('k0', bake), isTrue);
        expect(await images.ensure('k0', bake), isTrue);
        expect(overlay.puts, ['k0']);
        for (var i = 1; i <= overlayStampImagesKept; i++) {
          await images.ensure('k$i', bake);
        }
        expect(overlay.drops, ['k0']);
        expect(images.has('k0'), isFalse);

        images.forget();
        expect(images.has('k1'), isFalse);
        await images.ensure('k1', bake);
        expect(overlay.puts.where((k) => k == 'k1'), hasLength(2));
      },
    );

    test(
      'a put that lands after the window was hidden is not counted as held',
      () async {
        final overlay = FakeOverlay();
        final images = OverlayStampImages(overlay);
        final baking = Completer<Uint8List>();
        final put = images.ensure('k', () => baking.future);
        images.forget();
        baking.complete(Uint8List.fromList([1]));
        expect(await put, isFalse);
        expect(images.has('k'), isFalse);
      },
    );

    test(
      'a put still out when the window was shown again is not held',
      () async {
        final overlay = _SlowPuts();
        final images = OverlayStampImages(overlay);
        final put = images.ensure('k', () async => Uint8List.fromList([1]));
        await pumpEventQueue();
        images.forget();
        overlay.reply.complete(true);
        expect(await put, isFalse);
        expect(images.has('k'), isFalse);
      },
    );

    test('a frame names only a stamp whose picture the runner holds', () {
      final now = DateTime(2026, 11, 16, 12);
      final board = ScreenAnnotationBoard()
        ..apply(stampFrame(id: 'held'), now)
        ..apply(stampFrame(id: 'not', user: 'other', attachment: 'x'), now)
        ..markReady('held', now)
        ..markReady('not', now);
      final shapes = overlayShapesFor(
        board.liveAt(now),
        now,
        heldImage: (content) => content is EmojiStamp ? 'e:k' : null,
        reduceMotion: true,
      );
      expect(shapes, [
        const OverlayStamp(image: 'e:k', x: 0.4, y: 0.3, size: 0.12, alpha: 1),
      ]);
    });

    test('a stamp not yet ready is left out of the frame', () {
      final now = DateTime(2026, 11, 16, 12);
      final board = ScreenAnnotationBoard()..apply(stampFrame(), now);
      expect(
        overlayShapesFor(board.liveAt(now), now, heldImage: (_) => 'e:k'),
        isEmpty,
      );
    });
  });
}
