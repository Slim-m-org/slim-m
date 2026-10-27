// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A single continuous value control, built on Material's [Slider] rather
/// than a hand-rolled drag gesture: keyboard stepping, RTL layout, and the
/// slider semantics role all already exist there. Only the track and thumb
/// are custom-painted (via [SliderTrackShape] and [SliderComponentShape]),
/// which is what lets the microphone-meter variant keep Slider's gesture and
/// keyboard handling while still drawing a shape Material's own track never
/// produces.
///
/// Two shapes: normal (a 4px round track, a 14px round thumb, an inset
/// hairline) and `tall` (a 22px trough, a 12px-wide thumb, a 2px position
/// line instead of a filled portion) - the microphone meter in voice
/// settings. `meter` draws a live input level behind everything in both
/// shapes; `muted` dims the whole control and swaps the fill to a neutral
/// colour; `ticks` renders a row of mono labels beneath the track, with the
/// tick nearest the thumb picked out in accent.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../touch_targets.dart';
import 'focusable_tap_target.dart';
import 'slider_shapes.dart';

/// How much of the accent and of the disabled tone the live and silenced meters keep.
const activeMeterAlpha = 0.7;
const inactiveMeterAlpha = 0.5;

class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0,
    this.max = 100,
    this.divisions,
    this.keyStep,
    this.tall = false,
    this.meter,
    this.meterActive = true,
    this.muted = false,
    this.ticks,
    this.semanticLabel,
    this.autofocus = false,
    this.valueLabel,
    this.valueBubble = true,
    this.splitTrack = false,
  });

  final double value;
  final ValueChanged<double>? onChanged;

  /// Fired once when a drag is released, with the value it ended on.
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;

  /// How far one arrow-key press, or one screen-reader increase, moves the value; null keeps Material's step.
  final double? keyStep;

  /// The microphone-meter shape: a 22px trough instead of a 4px round track.
  final bool tall;

  /// A live input level (0-100), drawn behind the track independently of
  /// [value]. Not tied to [min]/[max]: in the source design it is a
  /// separate real-time signal, not a second position on the same scale.
  final double? meter;

  /// False draws [meter] in a neutral tone, for a level that is not being
  /// used, such as a microphone the input gate is silencing.
  final bool meterActive;
  final bool muted;

  /// Labels spread evenly beneath the track, from [min] to [max]. The one
  /// nearest the thumb is picked out in accent, so the highlight never
  /// disagrees with where the thumb is.
  final List<String>? ticks;
  final String? semanticLabel;

  /// Takes focus when it appears, so arrow keys move it at once.
  final bool autofocus;

  /// Formats the value for a bubble over the thumb, shown only while dragging or focused, and for screen readers.
  final String Function(double value)? valueLabel;

  /// False keeps [valueLabel] for screen readers only, for a slider that shows its value beside it.
  final bool valueBubble;

  /// A `tall` trough drawn in two tones either side of the thumb: quiet before it, heard after.
  final bool splitTrack;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
    _focusNode.onKeyEvent = _stepByKey;
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChange);
  }

  bool _commitOnKeyUp = false;

  /// A held key repeats fast; each repeat moves the value and the release commits it once.
  KeyEventResult _stepByKey(FocusNode _, KeyEvent event) {
    final step = widget.keyStep;
    final change = widget.onChanged;
    if (step == null || change == null) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final up = key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowDown;
    if (!up && !down) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      if (!_commitOnKeyUp) return KeyEventResult.ignored;
      _commitOnKeyUp = false;
      widget.onChangeEnd?.call(widget.value);
      return KeyEventResult.handled;
    }
    final next = _stepped(up ? step : -step);
    change(next);
    if (event is KeyRepeatEvent) {
      _commitOnKeyUp = true;
    } else {
      widget.onChangeEnd?.call(next);
    }
    return KeyEventResult.handled;
  }

  double _stepped(double delta) =>
      (widget.value + delta).clamp(widget.min, widget.max).toDouble();

  void _nudgeBySemantics(double delta) {
    final next = _stepped(delta);
    widget.onChanged?.call(next);
    widget.onChangeEnd?.call(next);
  }

  /// Material's own increase and decrease move a fixed share of the range, so a
  /// slider with a key step takes over those two actions and drags stay free.
  Widget _withStepActions(Widget slider, double value) {
    final step = widget.keyStep;
    String text(double v) => widget.valueLabel?.call(v) ?? v.round().toString();
    if (step == null || widget.onChanged == null) return slider;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: widget.semanticLabel,
      slider: true,
      enabled: true,
      focusable: true,
      focused: _focused,
      value: text(value),
      increasedValue: text(_stepped(step)),
      decreasedValue: text(_stepped(-step)),
      onIncrease: () => _nudgeBySemantics(step),
      onDecrease: () => _nudgeBySemantics(-step),
      child: slider,
    );
  }

  void _handleFocusChange() => setState(() => _focused = _focusNode.hasFocus);

  void _onHighlightModeChange(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  // Like FocusableTapTarget: the ring answers the keyboard, never a click or a drag.
  bool get _ringShown =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChange);
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  int get _nearestTick {
    final span = widget.max - widget.min;
    if (span <= 0) return 0;
    final fraction = ((widget.value - widget.min) / span).clamp(0.0, 1.0);
    return (fraction * (widget.ticks!.length - 1)).round();
  }

  double get _opacity {
    if (widget.muted) return 0.5;
    return widget.onChanged == null ? 0.7 : 1;
  }

  /// A live level reads at accent strength, a silenced one recedes behind it; the
  /// old accentSoft tint was 1.1-1.3:1 against the trough and so the silenced
  /// meter looked louder than the live one. A muted slider is already at half
  /// opacity, so its inactive meter skips the extra dimming.
  Color _meterColor(AppTokens tokens) {
    if (widget.meterActive) {
      return tokens.accentFill.withValues(alpha: activeMeterAlpha);
    }
    if (widget.muted) return tokens.textSecondary;
    return tokens.textDisabled.withValues(alpha: inactiveMeterAlpha);
  }

  Widget _tickLabels(AppTokens tokens) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < widget.ticks!.length; i++)
          Text(
            widget.ticks![i],
            style: AppText.micro.copyWith(
              color: i == _nearestTick ? tokens.accent : tokens.textSecondary,
              fontFamily: AppFonts.mono,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }

  /// Sits above the thumb; the inset is the slider's own overlay radius, where its track starts.
  Widget _bubble(AppTokens tokens, String text, double value) {
    final inset = focusRingGap + focusRingWidth + (widget.tall ? 14.0 : 12.0);
    final span = widget.max - widget.min;
    final fraction = span <= 0 ? 0.0 : (value - widget.min) / span;
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, box) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: inset + fraction * (box.maxWidth - 2 * inset),
                top: -AppSpacing.s4,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -1),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.textPrimary,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s8,
                        vertical: AppSpacing.s4,
                      ),
                      child: Text(
                        text,
                        style: AppText.caption.copyWith(
                          fontFamily: AppFonts.mono,
                          color: tokens.surfaceBase,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final value = widget.value.clamp(widget.min, widget.max).toDouble();
    final meterFraction =
        widget.meter == null ? null : (widget.meter! / 100).clamp(0.0, 1.0);

    final trackColor = tokens.surfaceSunken;
    final fillColor = widget.muted ? tokens.textSecondary : tokens.accentFill;
    final thumbColor = widget.muted ? tokens.textSecondary : tokens.textPrimary;
    final trackHeight = widget.tall ? 22.0 : 4.0;

    final track = TroughTrackShape(
      tall: widget.tall,
      borderColor: tokens.borderSubtle,
      trackColor: trackColor,
      fillColor: fillColor,
      meterColor: _meterColor(tokens),
      meterFraction: meterFraction,
      quietColor: widget.splitTrack
          ? tokens.textDisabled.withValues(alpha: 0.25)
          : null,
      hearColor: widget.splitTrack
          ? tokens.status.online.withValues(alpha: 0.35)
          : null,
    );
    final thumb = TroughThumbShape(
      tall: widget.tall,
      trackHeight: trackHeight,
      color: thumbColor,
      borderColor: tokens.surfaceBase,
    );

    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: trackHeight,
        // The custom shapes above paint every colour themselves; these
        // exist only as the sane fallback if a shape is ever swapped out.
        activeTrackColor: fillColor,
        inactiveTrackColor: trackColor,
        thumbColor: thumbColor,
        // The token doc for accentRing names this exact use: "the ring
        // around a pressed or dragged control".
        overlayColor: tokens.accentRing,
        overlayShape:
            RoundSliderOverlayShape(overlayRadius: widget.tall ? 14 : 12),
        trackShape: track,
        thumbShape: thumb,
        // A divided slider still reads as one continuous trough, as in the settings design.
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),
      child: Slider(
        value: value,
        min: widget.min,
        max: widget.max,
        divisions: widget.divisions,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onChanged: widget.onChanged,
        onChangeStart: (_) => setState(() => _dragging = true),
        onChangeEnd: (v) {
          setState(() => _dragging = false);
          widget.onChangeEnd?.call(v);
        },
        semanticFormatterCallback: widget.valueLabel,
      ),
    );

    // Silent on keyboard focus in the source design, same as the other form
    // controls; this package's own accessibility ring fills the gap.
    final ring = Opacity(
      opacity: _opacity,
      child: Container(
        padding: const EdgeInsets.all(focusRingGap),
        decoration: BoxDecoration(
          border: Border.all(
            color: _ringShown ? tokens.focusRing : Colors.transparent,
            width: focusRingWidth,
          ),
          borderRadius: BorderRadius.circular(AppRadii.full),
        ),
        // On touch the 24px-tall control grows to the touch floor; the track stays centred and looks the same.
        child: _withStepActions(
          AppTouchTargets.of(context)
              ? SizedBox(height: AppSizes.rowTouch, child: slider)
              : slider,
          value,
        ),
      ),
    );

    final label = widget.valueLabel;
    final showBubble = label != null &&
        widget.valueBubble &&
        widget.onChanged != null &&
        (_dragging || _focused);
    final withBubble = label == null
        ? ring
        : Stack(
            clipBehavior: Clip.none,
            children: [
              ring,
              if (showBubble) _bubble(tokens, label(value), value),
            ],
          );

    return Semantics(
      label: widget.semanticLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          withBubble,
          if (widget.ticks != null) ...[
            const SizedBox(height: AppSpacing.s8),
            _tickLabels(tokens),
          ],
        ],
      ),
    );
  }
}
