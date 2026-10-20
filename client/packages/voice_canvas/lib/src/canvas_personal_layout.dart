// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one viewer keeps of their personal view of a channel's canvas.
/// Decision 0082.
library;

import 'dart:convert';
import 'dart:ui';

import 'canvas_stroke.dart';

/// Most tile places kept per channel, so one busy call cannot grow the row forever.
const int personalPlacesCap = 64;

/// The camera and tile places a viewer chose for themselves, and whether they
/// were in the personal view when they left.
class CanvasPersonalLayout {
  const CanvasPersonalLayout({
    this.personal = false,
    this.camera,
    this.places = const {},
  });

  final bool personal;
  final Camera? camera;

  /// Tile key to the rect this viewer put it at.
  final Map<String, Rect> places;

  bool get isEmpty => !personal && camera == null && places.isEmpty;

  String encode() => jsonEncode({
        'personal': personal,
        if (camera case final c?) 'camera': [c.x, c.y, c.zoom],
        'places': {
          for (final e
              in places.entries.toList().reversed.take(personalPlacesCap))
            e.key: [e.value.left, e.value.top, e.value.width, e.value.height],
        },
      });

  /// Null for anything unreadable, so a damaged row reads as "nothing saved".
  static CanvasPersonalLayout? decode(String source) {
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic>) return null;
      final camera = _numbers(json['camera'], 3);
      final places = <String, Rect>{};
      final raw = json['places'];
      if (raw is Map<String, dynamic>) {
        for (final e in raw.entries) {
          final r = _numbers(e.value, 4);
          if (r != null && r[2] > 0 && r[3] > 0) {
            places[e.key] = Rect.fromLTWH(r[0], r[1], r[2], r[3]);
          }
        }
      }
      return CanvasPersonalLayout(
        personal: json['personal'] == true,
        camera: camera == null || camera[2] <= 0
            ? null
            : Camera(x: camera[0], y: camera[1], zoom: camera[2]),
        places: places,
      );
    } on FormatException {
      return null;
    }
  }

  static List<double>? _numbers(Object? value, int length) {
    if (value is! List || value.length != length) return null;
    if (value.any((n) => n is! num || !n.isFinite)) return null;
    return [for (final n in value) (n as num).toDouble()];
  }
}
