// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A 1 px image still gets a box a reader can see and tap, with its own pixels left at their size.
/// A break-it tester's 1x1 png drew as a single dot above its caption, and a small gif blew up blurry when the window lost focus.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_reveal.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

const _tiny = api.Attachment(
  id: 't1',
  filename: 'tiny1x1.png',
  contentType: 'image/png',
  size: 69,
);

const _smallGif = api.Attachment(
  id: 'g1',
  filename: 'small.gif',
  contentType: 'image/gif',
  size: 900,
);

final _onePixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60'
  'e6kgAAAABJRU5ErkJggg==',
);

Future<Uint8List> _pngOf(int edge) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, edge.toDouble(), edge.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(edge, edge);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// [attachment] inline at the top left, every fetch of it answered with [bytes].
Future<ProviderContainer> _pumpInline(
  WidgetTester tester,
  api.Attachment attachment,
  Uint8List bytes,
) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      attachmentPreviewBytesProvider.overrideWith((ref, key) async => bytes),
      attachmentBytesProvider(attachment.id).overrideWith((ref) async => bytes),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: AttachmentView(attachment: attachment),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return container;
}

/// Where the pixels of the decoded image [within] land, once it has decoded.
Future<Size> _paintedImageSize(WidgetTester tester, Finder within) async {
  final raw = find.descendant(
    of: within,
    matching: find.byWidgetPredicate((w) => w is RawImage && w.image != null),
  );
  for (var i = 0; i < 200 && raw.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  Rect? drawn;
  expect(
    tester.renderObject(raw),
    paints..something((method, arguments) {
      if (method != #drawImageRect) return false;
      drawn = arguments[2] as Rect;
      return true;
    }),
  );
  return drawn!.size;
}

final _firstFrame = find.byWidgetPredicate((w) => w is AttachmentFirstFrame);
final _moving = find.byWidgetPredicate((w) => w is Image);

void main() {
  testWidgets('a 1x1 image sits in a fingertip-sized box at its own size', (
    tester,
  ) async {
    await _pumpInline(tester, _tiny, Uint8List.fromList(_onePixel));

    final image = find.bySemanticsLabel('tiny1x1.png');
    expect(image, findsOneWidget);
    final box = tester.getRect(image);
    expect(box.width, greaterThanOrEqualTo(AppSizes.rowTouch));
    expect(box.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    expect(await _paintedImageSize(tester, _moving), const Size(1, 1));
  });

  testWidgets('a small gif keeps its size when the window loses focus and '
      'holds its first frame', (tester) async {
    final small = await tester.runAsync(() => _pngOf(24));
    final binding = TestWidgetsFlutterBinding.instance;
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    await _pumpInline(tester, _smallGif, small!);
    expect(await _paintedImageSize(tester, _moving), const Size(24, 24));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await pumpFrames(tester);

    expect(await _paintedImageSize(tester, _firstFrame), const Size(24, 24));
  });

  testWidgets('a small gif held for a tap keeps its size under the pointer', (
    tester,
  ) async {
    final small = await tester.runAsync(() => _pngOf(24));
    final container = await _pumpInline(tester, _smallGif, small!);
    await container
        .read(gifAutoplayControllerProvider.notifier)
        .select(GifAutoplay.tapToPlay);
    await pumpFrames(tester);
    expect(await _paintedImageSize(tester, _firstFrame), const Size(24, 24));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_firstFrame));
    await pumpFrames(tester);

    expect(await _paintedImageSize(tester, _moving), const Size(24, 24));
  });
}
