// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Generated avatar art: a few abstract patterns drawn from an account id.
///
/// The same painter fills the preview tile and the PNG that gets uploaded, so
/// what a member picks is what other members see.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Edge of the uploaded square; the server downsizes, so this only needs to be sharp.
const int kPatternAvatarPixels = 256;

enum AvatarPattern { rings, beams, marble, bands, orbit, tiles, sunrise }

/// A stable 32-bit hash, so the same account always gets the same art.
int patternSeed(String id) {
  var hash = 0x811c9dc5;
  for (final unit in id.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Four colours turned from [base] by the seed, so a theme keeps its own feel.
List<Color> patternPalette(Color base, int seed) {
  final hsl = HSLColor.fromColor(base);
  final turn = (seed % 360).toDouble();
  const offsets = [0.0, 48.0, 150.0, 210.0];
  const lightness = [0.38, 0.55, 0.72, 0.28];
  return [
    for (var i = 0; i < offsets.length; i++)
      hsl
          .withHue((hsl.hue + turn + offsets[i]) % 360)
          .withSaturation(hsl.saturation.clamp(0.45, 0.8))
          .withLightness(lightness[i])
          .toColor(),
  ];
}

class AvatarPatternPainter extends CustomPainter {
  const AvatarPatternPainter({
    required this.pattern,
    required this.seed,
    required this.base,
  });

  final AvatarPattern pattern;
  final int seed;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = patternPalette(base, seed);
    final rnd = math.Random(seed ^ pattern.index);
    final s = size.width;
    final mid = Offset(s / 2, s / 2);
    final paint = Paint()..isAntiAlias = true;
    canvas.drawRect(Offset.zero & size, paint..color = colors[0]);
    switch (pattern) {
      case AvatarPattern.rings:
        for (var i = 4; i >= 1; i--) {
          canvas.drawCircle(mid, s * i / 8, paint..color = colors[i % 4]);
        }
      case AvatarPattern.beams:
        for (var i = 0; i < 4; i++) {
          final y = s * i / 4 + rnd.nextDouble() * s / 12;
          final path = Path()
            ..moveTo(0, y)
            ..lineTo(s, y - s / 3)
            ..lineTo(s, y - s / 3 + s / 5)
            ..lineTo(0, y + s / 5)
            ..close();
          canvas.drawPath(path, paint..color = colors[(i + 1) % 4]);
        }
      case AvatarPattern.marble:
        for (var i = 1; i < 4; i++) {
          final centre = Offset(rnd.nextDouble() * s, rnd.nextDouble() * s);
          final radius = s * (0.3 + rnd.nextDouble() * 0.25);
          canvas.drawCircle(centre, radius, paint..color = colors[i]);
        }
      case AvatarPattern.bands:
        for (var i = 0; i < 6; i++) {
          canvas.drawRect(
            Rect.fromLTWH(s * i / 6, 0, s / 6, s),
            paint..color = colors[(i + rnd.nextInt(2)) % 4],
          );
        }
      case AvatarPattern.orbit:
        canvas.drawCircle(mid, s * 0.22, paint..color = colors[2]);
        final ring = Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.06
          ..color = colors[1];
        canvas.drawCircle(mid, s * 0.38, ring);
        final angle = rnd.nextDouble() * math.pi * 2;
        final moon = mid + Offset(math.cos(angle), math.sin(angle)) * s * 0.38;
        canvas.drawCircle(moon, s * 0.08, paint..color = colors[3]);
      case AvatarPattern.tiles:
        for (var row = 0; row < 4; row++) {
          for (var col = 0; col < 4; col++) {
            canvas.drawRect(
              Rect.fromLTWH(col * s / 4, row * s / 4, s / 4, s / 4),
              paint..color = colors[rnd.nextInt(4)],
            );
          }
        }
      case AvatarPattern.sunrise:
        canvas.drawRect(
          Rect.fromLTWH(0, s / 2, s, s / 2),
          paint..color = colors[3],
        );
        canvas.drawCircle(mid, s * 0.3, paint..color = colors[2]);
        canvas.drawCircle(mid, s * 0.16, paint..color = colors[1]);
    }
  }

  @override
  bool shouldRepaint(AvatarPatternPainter old) =>
      old.pattern != pattern || old.seed != seed || old.base != base;
}

typedef PatternRenderer =
    Future<Uint8List> Function(
      AvatarPattern pattern, {
      required String accountId,
      required Color base,
    });

/// The pattern as PNG bytes, ready for the avatar upload.
Future<Uint8List> renderPatternPng(
  AvatarPattern pattern, {
  required String accountId,
  required Color base,
}) async {
  final recorder = ui.PictureRecorder();
  final size = Size.square(kPatternAvatarPixels.toDouble());
  AvatarPatternPainter(
    pattern: pattern,
    seed: patternSeed(accountId),
    base: base,
  ).paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    kPatternAvatarPixels,
    kPatternAvatarPixels,
  );
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}
