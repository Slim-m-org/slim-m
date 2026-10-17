// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One image inside the fullscreen viewer: the zoom, the pan, the
/// drag-to-dismiss and the decode-failure state for a single attachment.
///
/// Split out of `fullscreen_image_viewer.dart` when that viewer became a
/// gallery. A message can carry several images, and it opened one with no way
/// to reach the rest; the page the reader is looking at is now this widget,
/// and the viewer around it owns the backdrop, the header and the paging.
///
/// It reports whether it is zoomed, because the viewer has to stop paging
/// while the reader is panning around inside one image - a horizontal drag
/// means pan then, not "next".
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class FullscreenImagePage extends StatefulWidget {
  const FullscreenImagePage({
    super.key,
    required this.filename,
    required this.bytes,
    required this.onDismiss,
    required this.onZoomChanged,
    this.heroTag,
  });

  final String filename;
  final Uint8List bytes;
  final VoidCallback onDismiss;

  /// Told when this page zooms in or back out, so the viewer can freeze and
  /// unfreeze paging.
  final ValueChanged<bool> onZoomChanged;

  /// The thumbnail's own identity tag, or null for a page with no thumbnail
  /// to fly from; see the viewer's library doc for why never a shared id.
  final Object? heroTag;

  @override
  State<FullscreenImagePage> createState() => _FullscreenImagePageState();
}

class _FullscreenImagePageState extends State<FullscreenImagePage> {
  static const double _maxScale = 8;
  static const double _zoomedAbove = 1.01;
  static const double _dismissDistance = 96;
  static const double _dismissVelocity = 700;

  final TransformationController _transform = TransformationController();
  bool _zoomed = false;
  double _dragged = 0;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_syncZoom);
  }

  @override
  void dispose() {
    _transform.removeListener(_syncZoom);
    _transform.dispose();
    super.dispose();
  }

  void _syncZoom() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > _zoomedAbove;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() => _dragged = math.max(0, _dragged + details.delta.dy));
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dragged >= _dismissDistance || velocity >= _dismissVelocity) {
      widget.onDismiss();
      return;
    }
    setState(() => _dragged = 0);
  }

  Widget _maybeHero(Widget child) =>
      widget.heroTag == null ? child : Hero(tag: widget.heroTag!, child: child);

  @override
  Widget build(BuildContext context) {
    // Zoomed, a drag is this page's own pan; dismissing would steal it.
    final dismissible = !_zoomed;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: dismissible ? _onDragUpdate : null,
      onVerticalDragEnd: dismissible ? _onDragEnd : null,
      child: Transform.translate(
        offset: Offset(0, _dragged),
        child: InteractiveViewer(
          transformationController: _transform,
          maxScale: _maxScale,
          child: _maybeHero(
            Image.memory(
              widget.bytes,
              fit: BoxFit.contain,
              semanticLabel: widget.filename,
              // The inline thumbnail already tried and failed to decode these same bytes; see the viewer's own doc comment.
              errorBuilder: (context, error, stackTrace) =>
                  FullscreenDecodeFailure(filename: widget.filename),
            ),
          ),
        ),
      ),
    );
  }
}

/// What renders in place of the image when the bytes fail to decode, on the
/// dark theme the fullscreen viewer always applies.
class FullscreenDecodeFailure extends StatelessWidget {
  const FullscreenDecodeFailure({super.key, required this.filename});

  final String filename;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s24),
        child: Text(
          'Could not open $filename.',
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      ),
    );
  }
}

/// What renders in place of a sibling image whose bytes could not be fetched.
///
/// Distinct from [FullscreenDecodeFailure] because the two are different
/// failures with different answers: bytes that will not decode are not worth
/// asking for again, but a fetch that failed is exactly the thing a retry
/// fixes. The inline thumbnail offers the same retry for the same reason.
class FullscreenLoadFailure extends StatelessWidget {
  const FullscreenLoadFailure({
    super.key,
    required this.filename,
    required this.onRetry,
  });

  final String filename;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Semantics(
        button: true,
        label: 'Retry loading $filename',
        child: GestureDetector(
          onTap: onRetry,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s24),
            child: Text(
              'Could not load $filename. Tap to retry.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
