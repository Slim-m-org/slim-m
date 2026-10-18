// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two drag surfaces of [AppColourPicker]: a saturation/value square and a
/// hue slider. Both take a pointer drag or the arrow keys.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import 'focus_ring.dart';

const double _thumb = 20;

/// Fine and coarse keyboard steps for a 0..1 value.
const double _step = 0.01;
const double _bigStep = 0.1;

/// Maps a local pointer position to a 0..1 pair and the arrow keys to a step.
class _Draggable extends StatelessWidget {
  const _Draggable({
    required this.label,
    required this.describe,
    required this.onPosition,
    required this.onStep,
    required this.child,
    required this.radius,
  });

  final String label;

  /// The spoken value after moving (dx, dy); (0, 0) is the current one.
  final String Function(double dx, double dy) describe;
  final void Function(Offset fraction) onPosition;

  /// Called with (dx, dy) in the arrow-key direction, up being negative dy.
  final void Function(double dx, double dy) onStep;
  final Widget child;
  final double radius;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final big = HardwareKeyboard.instance.isShiftPressed ? _bigStep : _step;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft) return _go(-big, 0);
    if (key == LogicalKeyboardKey.arrowRight) return _go(big, 0);
    if (key == LogicalKeyboardKey.arrowUp) return _go(0, -big);
    if (key == LogicalKeyboardKey.arrowDown) return _go(0, big);
    return KeyEventResult.ignored;
  }

  KeyEventResult _go(double dx, double dy) {
    onStep(dx, dy);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return AppFocusRing(
      radius: radius,
      builder: (context, onFocusChange) => Semantics(
        label: label,
        value: describe(0, 0),
        increasedValue: describe(_step, 0),
        decreasedValue: describe(-_step, 0),
        onIncrease: () => onStep(_step, 0),
        onDecrease: () => onStep(-_step, 0),
        child: Focus(
          onFocusChange: onFocusChange,
          onKeyEvent: _onKey,
          child: LayoutBuilder(
            builder: (context, box) {
              void at(Offset p) => onPosition(
                    Offset(
                      (p.dx / box.maxWidth).clamp(0.0, 1.0),
                      (p.dy / box.maxHeight).clamp(0.0, 1.0),
                    ),
                  );
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (d) {
                  Focus.of(context).requestFocus();
                  at(d.localPosition);
                },
                onPanUpdate: (d) => at(d.localPosition),
                child: child,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.colour});
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _thumb,
      height: _thumb,
      decoration: BoxDecoration(
        color: colour,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 3)],
      ),
    );
  }
}

class SaturationValueSquare extends StatelessWidget {
  const SaturationValueSquare({
    super.key,
    required this.hsv,
    required this.onChanged,
  });

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  @override
  Widget build(BuildContext context) {
    void set(double s, double v) =>
        onChanged(hsv.withSaturation(s.clamp(0, 1)).withValue(v.clamp(0, 1)));
    return _Draggable(
      label: 'Saturation and brightness',
      describe: (dx, dy) {
        final s = (hsv.saturation + dx).clamp(0, 1);
        final v = (hsv.value - dy).clamp(0, 1);
        return '${(s * 100).round()}% saturation, ${(v * 100).round()}% brightness';
      },
      radius: AppRadii.control,
      onPosition: (f) => set(f.dx, 1 - f.dy),
      onStep: (dx, dy) => set(hsv.saturation + dx, hsv.value - dy),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.white,
                    HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                  ],
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xFF000000)],
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, box) => Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: hsv.saturation * box.maxWidth - _thumb / 2,
                    top: (1 - hsv.value) * box.maxHeight - _thumb / 2,
                    child: IgnorePointer(
                      child: _Thumb(colour: hsv.toColor()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HueSlider extends StatelessWidget {
  const HueSlider({super.key, required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  static final _spectrum = [
    for (var h = 0; h <= 360; h += 60)
      HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    void set(double fraction) =>
        onChanged(hsv.withHue((fraction.clamp(0, 1) * 360).toDouble()));
    return SizedBox(
      height: _thumb + 4,
      child: _Draggable(
        label: 'Hue',
        describe: (dx, _) =>
            '${((hsv.hue / 360 + dx).clamp(0, 1) * 360).round()} degrees',
        radius: AppRadii.full,
        onPosition: (f) => set(f.dx),
        onStep: (dx, _) => set(hsv.hue / 360 + dx),
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            alignment: Alignment.centerLeft,
            clipBehavior: Clip.none,
            children: [
              Container(
                height: 12,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.full),
                  border: Border.all(color: tokens.borderStrong),
                  gradient: LinearGradient(colors: _spectrum),
                ),
              ),
              Positioned(
                left: hsv.hue / 360 * box.maxWidth - _thumb / 2,
                child: IgnorePointer(
                  child: _Thumb(
                    colour: HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
