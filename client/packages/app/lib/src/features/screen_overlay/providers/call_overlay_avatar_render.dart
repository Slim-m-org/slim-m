// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bakes one person's round picture for the call panel, as a PNG the runner draws as is (decision 0096).
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_design_system/design_system.dart'
    show
        AppAvatarGeometry,
        AppFonts,
        AppWeights,
        avatarTintFor,
        avatarTintInk,
        initialsFor;

/// Pixels per side: twice the 24 logical pixels the panel draws it at.
const callOverlayAvatarEdge = 48;

/// Largest side the source picture is decoded at before it is scaled into the disc.
const _decodeEdge = callOverlayAvatarEdge * 2;

/// A circle PNG of [picture] centre-cropped, or a tinted disc with [name]'s initials when there is none or it will not decode.
Future<Uint8List> renderOverlayAvatar({
  required String name,
  required String tintKey,
  Uint8List? picture,
}) async {
  final photo = picture == null ? null : await _decode(picture);
  const side = callOverlayAvatarEdge * 1.0;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..clipRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(0, 0, side, side),
        const ui.Radius.circular(side / 2),
      ),
    );
  if (photo != null) {
    _paintPhoto(canvas, photo);
  } else {
    _paintInitials(canvas, name, tintKey);
  }
  final baked = await recorder.endRecording().toImage(
    callOverlayAvatarEdge,
    callOverlayAvatarEdge,
  );
  final png = await baked.toByteData(format: ui.ImageByteFormat.png);
  baked.dispose();
  photo?.dispose();
  if (png == null) throw StateError('The overlay avatar did not encode.');
  return png.buffer.asUint8List();
}

Future<ui.Image?> _decode(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _decodeEdge,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } on Exception catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'An avatar would not decode for the call overlay; drawing initials',
      error,
      stack,
    );
    return null;
  }
}

void _paintPhoto(ui.Canvas canvas, ui.Image photo) {
  final square = (photo.width < photo.height ? photo.width : photo.height)
      .toDouble();
  canvas.drawImageRect(
    photo,
    ui.Rect.fromCenter(
      center: ui.Offset(photo.width / 2, photo.height / 2),
      width: square,
      height: square,
    ),
    const ui.Rect.fromLTWH(
      0,
      0,
      callOverlayAvatarEdge * 1.0,
      callOverlayAvatarEdge * 1.0,
    ),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
}

void _paintInitials(ui.Canvas canvas, String name, String tintKey) {
  const side = callOverlayAvatarEdge * 1.0;
  canvas.drawColor(avatarTintFor(tintKey), ui.BlendMode.src);
  final initials = initialsFor(name);
  if (initials.isEmpty) return;
  const geometry = AppAvatarGeometry(side);
  final paragraph =
      (ui.ParagraphBuilder(
              ui.ParagraphStyle(
                textAlign: ui.TextAlign.center,
                maxLines: 1,
                fontFamily: AppFonts.mono,
                fontSize: geometry.initialsFontSize,
                fontWeight: AppWeights.medium,
                height: 1,
              ),
            )
            ..pushStyle(ui.TextStyle(color: avatarTintInk))
            ..addText(initials))
          .build()
        ..layout(const ui.ParagraphConstraints(width: side));
  canvas.drawParagraph(paragraph, ui.Offset(0, (side - paragraph.height) / 2));
}
