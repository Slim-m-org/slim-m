// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The cropped avatar keeps the detail the source actually had.
///
/// The crop captures its own viewport, which is what keeps one implementation
/// of the pan-and-zoom geometry instead of two. It used to raster that viewport
/// straight to the 512px output, so the decoded photo was sampled bilinearly at
/// whatever ratio the crop needed - about 6x for an ordinary phone picture -
/// and the result read as soft however sharp the original was.
///
/// Measured rather than eyeballed: each case renders a ring pattern whose
/// frequency lands just inside what 512px can resolve, and compares the sheet's
/// output against the same source resampled to 512 by the image decoder, whose
/// area-averaging downscale is the best this size can do. Rastering small
/// reached 83 to 87 percent of that; rastering at the source's own resolution
/// and minifying afterwards reaches it.
///
/// The `sourceHeaderEdge` group below covers the other way this file used to
/// end up rastering small: `ImageDescriptor.width`/`.height` throw
/// `UnsupportedError` unconditionally on the web engine, which every avatar
/// uploaded from the web client hit, not just a picture with a genuinely
/// unreadable header - and confirms the fix decodes the real source edge
/// rather than guessing one, since a guess bigger than the source reopens
/// this same gap through an unnecessary upscale-then-minify round trip.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_crop_sheet.dart';
import 'package:slimm_design_system/design_system.dart';

/// A PNG of [edge] square carrying rings at a fixed fraction of its width, so
/// every source size puts the same frequency in front of the 512px output and
/// the numbers below are comparable across them.
Future<Uint8List> _ringsPng(int edge) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, edge.toDouble(), edge.toDouble()),
    Paint()..color = const Color(0xFF000000),
  );
  final paint = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = edge / 512;
  final centre = Offset(edge / 2, edge / 2);
  final step = edge ~/ 128;
  for (var r = step; r < edge; r += step) {
    canvas.drawCircle(centre, r.toDouble(), paint);
  }
  final image = await recorder.endRecording().toImage(edge, edge);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Mean absolute difference between horizontally adjacent pixels over the
/// middle of the image: high while fine detail still resolves, low once a
/// resample has smeared it away.
Future<({double detail, int edge})> _measure(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final w = image.width;
  final h = image.height;
  final bytes = raw!.buffer.asUint8List();
  var total = 0.0;
  var count = 0;
  for (var y = h ~/ 4; y < h * 3 ~/ 4; y++) {
    for (var x = w ~/ 4; x < w * 3 ~/ 4 - 1; x++) {
      total += (bytes[(y * w + x) * 4] - bytes[(y * w + x + 1) * 4]).abs();
      count++;
    }
  }
  image.dispose();
  codec.dispose();
  return (detail: total / count, edge: w);
}

/// The same source reduced to the output size by the image decoder: the best a
/// 512px square can carry, and so the bar the sheet has to reach.
Future<double> _idealDetail(Uint8List source, int outputEdge) async {
  final codec = await ui.instantiateImageCodec(
    source,
    targetWidth: outputEdge,
    targetHeight: outputEdge,
  );
  final image = (await codec.getNextFrame()).image;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  codec.dispose();
  return (await _measure(png!.buffer.asUint8List())).detail;
}

/// Opens the sheet on [source] and confirms it, the way a person does.
///
/// Every step runs inside [WidgetTester.runAsync] and yields to the real event
/// loop between pumps: the capture's PNG encode is real work in a real codec,
/// and a test that only pumps fake time waits on it forever.
Future<Uint8List?> _cropped(WidgetTester tester, Uint8List source) async {
  Uint8List? out;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async =>
                  out = await showAvatarCropSheet(context, source),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.text('Use picture'), findsOneWidget);
    await tester.tap(find.text('Use picture'));
    await _settle(tester);
  });
  return out;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('a picture smaller than the output still crops to 512', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Under the output edge, so the reduction is skipped entirely.
    late Uint8List source;
    await tester.runAsync(() async => source = await _ringsPng(256));

    final out = await _cropped(tester, source);
    expect(out, isNotNull);
    late ({double detail, int edge}) result;
    await tester.runAsync(() async => result = await _measure(out!));
    expect(result.edge, 512);
  });

  // 2x, 4x and 8x the output edge: the range a picked photo actually spans.
  for (final sourceEdge in const [1024, 2048, 4096]) {
    testWidgets('a $sourceEdge source crops to all the detail 512px holds', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late Uint8List source;
      late double ideal;
      await tester.runAsync(() async {
        source = await _ringsPng(sourceEdge);
        ideal = await _idealDetail(source, 512);
      });

      final out = await _cropped(tester, source);
      expect(out, isNotNull, reason: 'the sheet returned no picture');

      late ({double detail, int edge}) result;
      await tester.runAsync(() async => result = await _measure(out!));

      expect(result.edge, 512, reason: 'the output edge is fixed');
      expect(
        result.detail,
        greaterThan(ideal * 0.97),
        reason:
            'a $sourceEdge source cropped to ${result.detail} detail against '
            '$ideal achievable; rastering the viewport straight to the output '
            'size is how that gap opens',
      );
    });
  }

  group('sourceHeaderEdge', () {
    test('reads the shorter side straight from the header', () async {
      final png = await _ringsPng(777);
      expect(await sourceHeaderEdge(png), 777);
    });

    // The one path every web call takes; see decodedSourceEdge's doc comment.
    test(
      'the decode fallback reaches the same real edge a header would',
      () async {
        final png = await _ringsPng(777);
        expect(await decodedSourceEdge(png), 777);
      },
    );

    test(
      'a picture nothing can decode returns null rather than a guess',
      () async {
        final garbage = Uint8List.fromList([1, 2, 3, 4]);
        expect(await sourceHeaderEdge(garbage), isNull);
      },
    );
  });
}
