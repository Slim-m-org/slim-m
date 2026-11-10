// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drawn pictures and the gestures the crop and emoji review cases need.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sky, a sun and two hills: enough structure that a crop and a zoom read.
Future<Uint8List> reviewPhotoPng(WidgetTester tester, int w, int h) async {
  final png = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(w.toDouble(), h.toDouble());
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          const Color(0xFF2B5FA8),
          const Color(0xFFF2B36B),
        ]),
    );
    canvas.drawCircle(
      Offset(size.width * 0.68, size.height * 0.32),
      size.shortestSide * 0.12,
      Paint()..color = const Color(0xFFFFE9A8),
    );
    for (final (dy, color) in const [
      (0.62, Color(0xFF3C6E47)),
      (0.78, Color(0xFF244D33)),
    ]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(
            size.width * (dy == 0.62 ? 0.3 : 0.7),
            size.height * dy,
          ),
          width: size.width * 1.1,
          height: size.height * 0.5,
        ),
        Paint()..color = color,
      );
    }
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  return png!;
}

/// Lets queued image decodes land, which the test's fake clock never does.
Future<void> settleImages(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A two-finger spread over the middle of the screen.
Future<void> pinchOut(WidgetTester tester) async {
  final centre = tester.getCenter(
    find.byWidgetPredicate((w) => w is InteractiveViewer),
  );
  final a = await tester.startGesture(centre - const Offset(10, 0));
  final b = await tester.startGesture(centre + const Offset(10, 0));
  await tester.pump();
  for (var i = 1; i <= 6; i++) {
    await a.moveTo(centre - Offset(10.0 + i * 12, 0));
    await b.moveTo(centre + Offset(10.0 + i * 12, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await b.up();
  await tester.pump();
}

/// A round face on a flat colour: a stand-in for a small emoji image.
Future<Uint8List> reviewEmojiPng(WidgetTester tester, Color colour) async {
  final png = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(const Offset(64, 64), 60, Paint()..color = colour);
    final dark = Paint()..color = const Color(0xFF1B1B1F);
    canvas.drawCircle(const Offset(44, 52), 8, dark);
    canvas.drawCircle(const Offset(84, 52), 8, dark);
    canvas.drawArc(
      const Rect.fromLTWH(38, 56, 52, 36),
      0.2,
      2.7,
      false,
      dark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round,
    );
    final image = await recorder.endRecording().toImage(128, 128);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  return png!;
}
