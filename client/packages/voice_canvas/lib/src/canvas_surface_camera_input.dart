// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_surface.dart';

/// The wheel, the web's scale signal and the two-finger pinch: everything
/// that moves the camera rather than a tool.
extension _CanvasSurfaceCameraInput on _CanvasSurfaceState {
  /// A plain wheel notch pans vertically, Ctrl/Cmd zooms and Shift adds the horizontal axis; a trackpad's two-axis swipe keeps panning both ways, and a middle-mouse drag ([_beginPan]) gives a mouse free motion.
  /// The arithmetic is the pure [cameraAfterWheelScroll] because a presence tile in the app layer sits in front of this surface and must answer the same gesture; two copies would drift.
  void _signal(PointerSignalEvent event) {
    final document = widget.document;
    // On the web a ctrl-wheel or trackpad pinch arrives as a scale event, never as a scroll.
    if (event is PointerScaleEvent) {
      // A mouse wheel notch arrives as one big scale, a trackpad pinch as many small ones.
      final scale = event.kind == PointerDeviceKind.mouse
          ? event.scale.clamp(minWheelZoomStep, maxWheelZoomStep)
          : event.scale;
      document.setCamera(
        cameraAfterZoom(
          document.camera,
          focal: event.localPosition,
          zoomTarget: document.camera.zoom * scale,
          zoomFloor: document.zoomFloor,
        ),
      );
      return;
    }
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    document.setCamera(
      cameraAfterWheelScroll(
        document.camera,
        focal: event.localPosition,
        dx: event.scrollDelta.dx,
        dy: event.scrollDelta.dy,
        zoomModifier: keys.isControlPressed || keys.isMetaPressed,
        horizontalModifier: keys.isShiftPressed,
        zoomFloor: document.zoomFloor,
      ),
    );
  }

  void _scaleBegin(ScaleStartDetails details) {
    _scaleStart = widget.document.camera;
    _scaleFocalWorld = _toWorld(details.localFocalPoint);
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    final start = _scaleStart;
    final anchor = _scaleFocalWorld;
    if (start == null || anchor == null || details.pointerCount < 2) return;
    // A resting palm beside a stylus is not a pinch.
    if (_stylusPointers.isNotEmpty) return;
    final document = widget.document;
    document.setCamera(start.copyWith(zoom: start.zoom * details.scale));
    final camera = document.camera;
    final focal = details.localFocalPoint;
    document.setCamera(
      camera.copyWith(
        x: anchor.dx - focal.dx / camera.zoom,
        y: anchor.dy - focal.dy / camera.zoom,
      ),
    );
  }
}
