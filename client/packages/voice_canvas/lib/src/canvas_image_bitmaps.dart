// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The decoded bitmap of each image object: attaching one, giving up on one, and freeing one without removing its object.
library;

import 'dart:ui' as ui;

import 'canvas_stroke.dart';

class CanvasImageBitmaps {
  CanvasImageBitmaps({required this.live, required this.changed});

  /// The live object named [id], or null when it is unknown or dead.
  final CanvasStroke? Function(String id) live;

  /// Repaints after [stroke] changed how it draws.
  final void Function(CanvasStroke stroke) changed;

  /// Attaches [image] to a live image object; it is disposed instead if the object died while the decode ran, since nothing else would free it.
  void attach(String id, ui.Image image) {
    final stroke = live(id);
    if (stroke == null) {
      image.dispose();
      return;
    }
    // A tier swap or a repeat paste replaces a held bitmap, which nothing else frees.
    if (!identical(stroke.image, image)) stroke.image?.dispose();
    stroke.image = image;
    stroke.imageLoadFailed = false;
    changed(stroke);
  }

  /// Marks an image whose bytes could not be fetched, so the painter draws a placeholder; a bitmap that already landed is never blanked by a failure racing behind it.
  void markFailed(String id) {
    final stroke = live(id);
    if (stroke == null || stroke.image != null) return;
    stroke.imageLoadFailed = true;
    changed(stroke);
  }

  /// Frees a held bitmap without removing the object, which stops painting until it is fetched and hydrated again.
  void evict(String id) {
    final stroke = live(id);
    final image = stroke?.image;
    if (image == null) return;
    stroke!.image = null;
    image.dispose();
    changed(stroke);
  }
}
