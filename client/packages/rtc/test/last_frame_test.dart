// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A paused or reconnecting tile shows its last real frame blurred instead of a flat colour.
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/first_frame_gate.dart';

Future<ui.Image> _image() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(List.filled(4 * 4 * 4, 200)),
    4,
    4,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  _captureTest();
  testWidgets(
      'the fallback shows until a frame is remembered, then the blurred '
      'frame replaces it', (tester) async {
    final store = LastFrameStore();
    final image = (await tester.runAsync(_image))!;
    const fallback = ColoredBox(key: ValueKey('flat'), color: Colors.red);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BlurredLastFrame(
          tileKey: 'screen:a',
          fallback: fallback,
          store: store,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('flat')), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);

    store.put('screen:a', image);
    await tester.pump();
    expect(find.byKey(const ValueKey('flat')), findsNothing);
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
  });

  test('the store keeps only the newest frames', () async {
    final store = LastFrameStore(capacity: 2);
    final image = await _image();
    store
      ..put('a', image)
      ..put('b', image)
      ..put('c', image);
    expect(store.imageFor('a'), isNull);
    expect(store.imageFor('c'), isNotNull);
    expect(store.length, 2);
  });

  testWidgets(
      'a tile with a painted frame refreshes its remembered frame, one '
      'without does not', (tester) async {
    final image = (await tester.runAsync(_image))!;
    final tracker = FirstFrameTracker();
    addTearDown(tracker.dispose);
    var snapshots = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RememberLastFrame(
          tileKey: 'camera:remembered',
          tracker: tracker,
          refresh: const Duration(seconds: 1),
          snapshot: (_) async {
            snapshots++;
            return image;
          },
          child: const SizedBox(width: 50, height: 50),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(snapshots, 0);
    expect(LastFrameStore.instance.imageFor('camera:remembered'), isNull);

    tracker.markFirstFrame();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(snapshots, 1);
    expect(LastFrameStore.instance.imageFor('camera:remembered'), image);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(snapshots, 1);
  });
}

void _captureTest() {
  testWidgets('a real boundary is copied at most 160 wide', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: 640,
              height: 360,
              child: ColoredBox(color: Colors.green),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await tester.runAsync(() => snapshotLastFrame(boundary));
    expect(image, isNotNull);
    expect(image!.width, lessThanOrEqualTo(160));
    expect(image.width, greaterThan(100));
  });
}
