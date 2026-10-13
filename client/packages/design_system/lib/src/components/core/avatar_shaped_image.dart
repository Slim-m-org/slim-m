// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An image, or a flat disc, shaped as a rounded rect (a circle when the
/// radius is half the size) by baking the shape into a bitmap at three times
/// the painted pixels and drawing that bitmap scaled down.
///
/// The Linux desktop renders with Impeller on OpenGL, which anti-aliases a
/// clip or a shape fill only partly: measured on the owner's renderer, a
/// 32px clipped circle had about 60 blended edge pixels, against about 110
/// for this supersampled bake, close to a true anti-aliased edge. The bake is
/// what makes an avatar a smooth circle on a 1x display.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// How many times the painted pixels a shape is baked at.
const int _supersample = 3;

/// Largest bake edge, so a huge avatar does not allocate a huge texture.
const int _maxBake = 1024;

int _bakeEdge(double size, double devicePixelRatio) =>
    math.min(_maxBake, (size * devicePixelRatio * _supersample).ceil());

/// [source] cropped to a centred square, shaped, at [edge] pixels.
ui.Image _bake(ui.Image source, int edge, double radiusFraction) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final side = edge.toDouble();
  final square = math.min(source.width, source.height).toDouble();
  final crop = Rect.fromCenter(
    center: Offset(source.width / 2, source.height / 2),
    width: square,
    height: square,
  );
  canvas.clipRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, side, side),
      Radius.circular(side * radiusFraction),
    ),
  );
  canvas.drawImageRect(
    source,
    crop,
    Rect.fromLTWH(0, 0, side, side),
    Paint()..filterQuality = FilterQuality.medium,
  );
  return recorder.endRecording().toImageSync(edge, edge);
}

final Map<(int, int), ui.Image> _discMasks = {};

/// A white shape at [edge] pixels, shared by every flat disc of that size.
ui.Image _discMask(int edge, double radiusFraction) {
  final key = (edge, (radiusFraction * 1000).round());
  return _discMasks.putIfAbsent(key, () {
    final recorder = ui.PictureRecorder();
    final side = edge.toDouble();
    Canvas(recorder).drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, side, side),
        Radius.circular(side * radiusFraction),
      ),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    return recorder.endRecording().toImageSync(edge, edge);
  });
}

void _drawScaled(Canvas canvas, Size size, ui.Image image, Paint paint) {
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    paint,
  );
}

/// A flat [color] disc (or rounded square) with a supersampled edge.
class AppShapedDisc extends StatelessWidget {
  const AppShapedDisc({
    super.key,
    required this.color,
    required this.size,
    required this.radius,
    this.child,
  });

  final Color color;
  final double size;
  final double radius;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final edge = _bakeEdge(size, MediaQuery.devicePixelRatioOf(context));
    return CustomPaint(
      size: Size.square(size),
      painter: _DiscPainter(_discMask(edge, radius / size), color),
      child: SizedBox.square(dimension: size, child: child),
    );
  }
}

class _DiscPainter extends CustomPainter {
  _DiscPainter(this.mask, this.color);

  final ui.Image mask;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => _drawScaled(
        canvas,
        size,
        mask,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
      );

  @override
  bool shouldRepaint(_DiscPainter oldDelegate) =>
      oldDelegate.mask != mask || oldDelegate.color != color;
}

class AppShapedImage extends StatefulWidget {
  const AppShapedImage({
    super.key,
    required this.image,
    required this.size,
    required this.radius,
    required this.errorBuilder,
    this.filterQuality = FilterQuality.medium,
  });

  final ImageProvider image;
  final double size;
  final double radius;

  /// Drawn when the image cannot be loaded.
  final WidgetBuilder errorBuilder;

  /// Medium, not high: measured on Skia, high aliased a minified photo worse.
  final FilterQuality filterQuality;

  @override
  State<AppShapedImage> createState() => _AppShapedImageState();
}

class _AppShapedImageState extends State<AppShapedImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  ui.Image? _baked;
  bool _failed = false;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
    _rebake();
  }

  @override
  void didUpdateWidget(AppShapedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image || oldWidget.size != widget.size) {
      _resolve();
    }
    if (oldWidget.radius != widget.radius || oldWidget.size != widget.size) {
      _rebake();
    }
  }

  void _resolve() {
    final stream = widget.image.resolve(
      createLocalImageConfiguration(context, size: Size.square(widget.size)),
    );
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _rebake() {
    final info = _info;
    if (info == null) return;
    final edge = _bakeEdge(
      widget.size,
      MediaQuery.devicePixelRatioOf(context),
    );
    _baked?.dispose();
    _baked = _bake(info.image, edge, widget.radius / widget.size);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    setState(() {
      _info?.dispose();
      _info = info;
      _failed = false;
      _rebake();
    });
  }

  void _onError(Object error, StackTrace? stack) {
    setState(() => _failed = true);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    _baked?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.errorBuilder(context);
    final baked = _baked;
    return SizedBox.square(
      dimension: widget.size,
      child: baked == null
          ? null
          : CustomPaint(painter: _ImagePainter(baked, widget.filterQuality)),
    );
  }
}

class _ImagePainter extends CustomPainter {
  _ImagePainter(this.image, this.filterQuality);

  final ui.Image image;
  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) =>
      _drawScaled(canvas, size, image, Paint()..filterQuality = filterQuality);

  @override
  bool shouldRepaint(_ImagePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.filterQuality != filterQuality;
}
