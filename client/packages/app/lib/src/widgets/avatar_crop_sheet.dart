// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Square-crops a picked image before it is uploaded as an avatar.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:slimm_design_system/design_system.dart';

import 'image_downscale.dart';

/// The edge of the encoded result, in pixels.
///
/// A phone photo is routinely 3 to 5 MB and the server caps an avatar at 2 MB,
/// so uploading the picked file unchanged failed for most real pictures. This
/// re-encodes at a size an avatar is ever drawn at, which lands far under the
/// cap as a side effect of doing the crop the user asked for.
const int _outputEdge = 512;

/// Ceiling on the intermediate capture, in pixels.
///
/// The capture is held in memory as raw pixels, so this is 64 MB at 4 bytes a
/// pixel and the reason the source's own size does not set it. 4096 is already
/// 8x the output edge, past which the minification below has nothing left to
/// recover.
const int _maxCaptureEdge = 4096;

/// The shorter side, in pixels, of the image encoded in [bytes].
///
/// Tries [ui.ImageDescriptor] first, which reads it from the header without
/// a decode. That throws `UnsupportedError` unconditionally on the web
/// engine - not only for a picture with a genuinely unreadable header - so
/// every web upload used to fall back to a guess instead of the source's
/// real size, silently rastering straight to the output edge and reintroducing
/// the soft, bilinear-stretched picture this file otherwise avoids. The
/// fallback here decodes the picture instead of guessing: extra cost on the
/// path that would otherwise skip it, but no cost at all against what
/// `Image.memory` already pays to show the same bytes on screen, and no
/// guess to be wrong about.
///
/// A public top-level function, rather than staying inline in the sheet's
/// state, exists so a test can call it directly: a test running on the VM
/// has no way to trigger the real web throw by feeding it a bad picture,
/// since a header the VM's own decoder cannot parse cannot be displayed by
/// the sheet either. Exercising this function alone is what lets a VM test
/// cover the fallback that is every web caller's only path.
@visibleForTesting
Future<int?> sourceHeaderEdge(Uint8List bytes) async {
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final shorter = math.min(descriptor.width, descriptor.height);
    descriptor.dispose();
    return shorter;
  } catch (_) {
    return decodedSourceEdge(bytes);
  }
}

/// [sourceHeaderEdge]'s fallback: the shorter side of an actual decode of
/// [bytes], or null if the picture cannot be decoded at all. Exposed
/// separately, and also `@visibleForTesting`, so a test can confirm this
/// reaches the same real answer [sourceHeaderEdge] would from a readable
/// header, rather than only confirming that some fallback ran.
@visibleForTesting
Future<int?> decodedSourceEdge(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final shorter = math.min(frame.image.width, frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return shorter;
  } catch (_) {
    return null;
  }
}

/// Shows [bytes] in a square viewport the user can pan and zoom, and returns
/// the cropped PNG, or null if they backed out.
Future<Uint8List?> showAvatarCropSheet(
  BuildContext context,
  Uint8List bytes, {
  bool circular = true,
}) {
  return showAppSheet<Uint8List>(
    context,
    maxWidth: 520,
    builder: (_) => _AvatarCropSheet(bytes: bytes, circular: circular),
  );
}

class _AvatarCropSheet extends StatefulWidget {
  const _AvatarCropSheet({required this.bytes, required this.circular});

  final Uint8List bytes;

  /// An avatar is drawn round; a space icon is a rounded square.
  final bool circular;

  @override
  State<_AvatarCropSheet> createState() => _AvatarCropSheetState();
}

class _AvatarCropSheetState extends State<_AvatarCropSheet> {
  final _boundary = GlobalKey();
  final _controller = TransformationController();
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Captures the viewport rather than reading the pan and zoom back out of
  /// the transform: what is inside the square is exactly what was shown, with
  /// no second implementation of the same geometry to disagree with it.
  ///
  /// Captured at the source picture's own resolution and minified afterwards,
  /// rather than rastered straight to [_outputEdge]. Rastering the viewport at
  /// the output size samples the decoded photo bilinearly at whatever ratio the
  /// crop happens to need - 6x for an ordinary phone picture - and throws away
  /// detail a box filter keeps. `avatar_crop_sharpness_test.dart` measures both
  /// paths against an ideal resample of the same source: capturing small landed
  /// at 86% of it, capturing large and minifying lands on it.
  ///
  /// Both buttons are disabled while this runs, so a throw anywhere in the
  /// raster-and-encode path used to leave the sheet on "Working..." with no way
  /// out and an unhandled async error behind it. It pops with nothing instead,
  /// which reads to the caller exactly like a cancel - the picture is still on
  /// disk and the whole step is repeatable. A reduction that fails separately
  /// falls back to the captured bytes, which are a correct picture, just the
  /// softer one this change exists to improve on.
  Future<void> _confirm() async {
    setState(() => _busy = true);
    final object = _boundary.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    Uint8List? out;
    try {
      out = await _capture(object);
    } catch (_) {
      // Raster and encode are the one unrecoverable step here; see the doc.
      out = null;
    }
    if (!mounted) return;
    Navigator.of(context).pop(out);
  }

  /// Rasters [object] at [_captureEdge] and reduces it to the output size.
  Future<Uint8List?> _capture(RenderRepaintBoundary object) async {
    final captureEdge = await _captureEdge();
    final image = await object.toImage(
      pixelRatio: captureEdge / object.size.width,
    );
    final ByteData? captured;
    try {
      captured = await image.toByteData(format: ui.ImageByteFormat.png);
    } finally {
      image.dispose();
    }
    final bytes = captured?.buffer.asUint8List();
    if (bytes == null || captureEdge == _outputEdge) return bytes;
    // A failed reduction still has a correct, merely softer picture in hand.
    return await minifiedPng(bytes, width: _outputEdge, height: _outputEdge) ??
        bytes;
  }

  /// The edge to raster the viewport at: the source's own shorter side, which
  /// is what one viewport-width of it is worth at zoom 1, bounded below by the
  /// output and above by [_maxCaptureEdge].
  ///
  /// [_maxCaptureEdge] only when [sourceHeaderEdge] cannot learn the source's
  /// real size at all (a picture nothing can decode), rather than a smaller
  /// guess: capturing bigger than the source costs compute, sending
  /// [_capture] through an upscale-then-minify round trip it would not
  /// otherwise need, but capturing smaller than it costs the detail this file
  /// exists to keep, exactly as [_outputEdge] used to on every web upload.
  Future<int> _captureEdge() async {
    final shorter = await sourceHeaderEdge(widget.bytes);
    if (shorter == null) return _maxCaptureEdge;
    return shorter.clamp(_outputEdge, _maxCaptureEdge);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // The viewport is square, so it has to fit the shorter side as well.
    // Sized on width alone it was 1248pt tall in a 900pt window, which pushed
    // Cancel and Use picture off the bottom of the screen on every desktop.
    final size = MediaQuery.sizeOf(context);
    final edge = math.min(size.width - AppSpacing.s32, size.height * 0.5);
    final framed = RepaintBoundary(
      key: _boundary,
      child: SizedBox(
        width: edge,
        height: edge,
        child: InteractiveViewer(
          transformationController: _controller,
          minScale: 1,
          maxScale: 5,
          clipBehavior: Clip.hardEdge,
          child: Image.memory(
            widget.bytes,
            fit: BoxFit.cover,
            width: edge,
            height: edge,
          ),
        ),
      ),
    );
    final picture = widget.circular
        ? ClipOval(child: framed)
        : ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.card),
            child: framed,
          );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          0,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Crop your picture', style: AppText.title),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Drag to move, pinch to zoom.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s16),
            picture,
            const SizedBox(height: AppSpacing.s16),
            Row(
              children: [
                Expanded(
                  child: AppButton(
                    label: 'Cancel',
                    variant: AppButtonVariant.ghost,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: AppButton(
                    label: _busy ? 'Working...' : 'Use picture',
                    variant: AppButtonVariant.primary,
                    onPressed: _busy ? null : _confirm,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
