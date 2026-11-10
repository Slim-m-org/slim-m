// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picture the seeded image object shows, drawn once per mount.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// A real picture for the seeded image: a sky, a sun and two ridges.
Future<ui.Image> reviewPhoto() async {
  const size = Size(960, 640);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final sky = Paint()
    ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), const [
      Color(0xFF3F6FB5),
      Color(0xFFF2C48D),
    ]);
  canvas.drawRect(Offset.zero & size, sky);
  canvas.drawCircle(
    const Offset(700, 210),
    90,
    Paint()..color = const Color(0xFFFFE9A8),
  );
  Path ridge(double base, double amp, double phase) {
    final path = Path()..moveTo(0, size.height);
    for (var x = 0.0; x <= size.width; x += 8) {
      path.lineTo(x, base + math.sin(x / 140 + phase) * amp);
    }
    return path
      ..lineTo(size.width, size.height)
      ..close();
  }

  canvas.drawPath(ridge(430, 50, 0), Paint()..color = const Color(0xFF4C6A8C));
  canvas.drawPath(ridge(510, 40, 2), Paint()..color = const Color(0xFF2E4A3B));
  return recorder.endRecording().toImage(960, 640);
}
