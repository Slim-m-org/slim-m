// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Places the stamp in hand on a shared screen's tile (decision 0121): a tap
/// places it at the default size, a press and drag sizes it around the press
/// point, and nothing is sent until the finger or button lifts.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../../composer/widgets/composer_clipboard_paste.dart';
import '../../screen_overlay/providers/screen_annotation_mapping.dart';
import '../../screen_overlay/providers/screen_stamp_timing.dart';
import '../../screen_overlay/providers/stamp_content.dart';
import 'screen_stamp_marks.dart';
import 'stamp_view.dart';

/// How strongly the stamp under the pointer shows before it is placed.
const _ghostOpacity = 0.6;

/// The size a drag from [centre] to [to] gives, as a fraction of [screenHeight]: the longest side is twice the drag.
double stampDragSize(Offset centre, Offset to, double screenHeight) =>
    screenHeight <= 0
    ? stampDefaultSize
    : clampStampSize(2 * (to - centre).distance / screenHeight);

class ScreenStampPlacer extends StatefulWidget {
  const ScreenStampPlacer({
    super.key,
    required this.content,
    required this.armed,
    required this.aspectOf,
    required this.onPlace,
    required this.onCancel,
    this.onPaste,
  });

  /// Where the shared screen sits in the tile.
  final Rect content;
  final StampContent armed;
  final double? Function(StampContent content) aspectOf;

  /// The centre, 0 to 1 across the screen, and the size.
  final void Function(Offset centre, double size) onPlace;

  /// Escape or a right-click puts the stamp down.
  final VoidCallback onCancel;

  /// Ctrl+V or Cmd+V: arms the picture on the clipboard under the pointer, and nothing is sent before a tap.
  final VoidCallback? onPaste;

  @override
  State<ScreenStampPlacer> createState() => _ScreenStampPlacerState();
}

class _ScreenStampPlacerState extends State<ScreenStampPlacer> {
  Offset? _hover;
  Offset? _press;
  double? _dragSize;

  void _place(Offset at, double size) {
    setState(() {
      _press = null;
      _dragSize = null;
    });
    widget.onPlace(toNormalised(at, widget.content), size);
  }

  void _drag(DragUpdateDetails d) {
    final press = _press;
    if (press == null) return;
    setState(
      () => _dragSize = stampDragSize(
        press,
        d.localPosition,
        widget.content.height,
      ),
    );
  }

  void _endDrag() {
    final press = _press;
    final size = _dragSize;
    if (press != null && size != null) _place(press, size);
  }

  @override
  Widget build(BuildContext context) {
    final press = _press;
    final dragSize = _dragSize;
    final hover = _hover;
    final Widget? ghost = switch ((press, dragSize, hover)) {
      (final at?, final size?, _) => _ghost(at, size, 1),
      (_, _, final at?) => _ghost(at, stampDefaultSize, _ghostOpacity),
      _ => null,
    };
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        final paste = widget.onPaste;
        if (paste != null && isClipboardPasteChord(event)) {
          paste();
          return KeyEventResult.handled;
        }
        if (event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        widget.onCancel();
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        onHover: (e) => setState(() => _hover = e.localPosition),
        onExit: (_) => setState(() => _hover = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _place(d.localPosition, stampDefaultSize),
          onSecondaryTapUp: (_) => widget.onCancel(),
          onPanDown: (d) => _press = d.localPosition,
          onPanUpdate: _drag,
          onPanEnd: (_) => _endDrag(),
          onPanCancel: () => setState(() {
            _press = null;
            _dragSize = null;
          }),
          child: Stack(
            clipBehavior: Clip.none,
            children: [if (ghost != null) ghost],
          ),
        ),
      ),
    );
  }

  Widget _ghost(Offset at, double size, double opacity) => Positioned.fromRect(
    rect: stampBox(
      widget.content,
      toNormalised(at, widget.content),
      size,
      widget.aspectOf(widget.armed) ?? 1,
    ),
    child: IgnorePointer(
      child: Opacity(
        opacity: opacity,
        child: StampView(content: widget.armed),
      ),
    ),
  );
}
