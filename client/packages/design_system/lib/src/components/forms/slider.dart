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

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../touch_targets.dart';
import 'focusable_tap_target.dart';
import 'slider_shapes.dart';

class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 100,
    this.divisions,
    this.tall = false,
    this.meter,
    this.muted = false,
    this.ticks,
    this.focusNode,
    this.semanticLabel,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;

  /// The microphone-meter shape: a 22px trough instead of a 4px round track.
  final bool tall;

  /// A live input level (0-100), drawn behind the track independently of
  /// [value]. Not tied to [min]/[max]: in the source design it is a
  /// separate real-time signal, not a second position on the same scale.
  final double? meter;
  final bool muted;

  /// Labels spread evenly beneath the track, from [min] to [max]. The one
  /// nearest the thumb is picked out in accent, so the highlight never
  /// disagrees with where the thumb is.
  final List<String>? ticks;
  final FocusNode? focusNode;
  final String? semanticLabel;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  late final FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() => setState(() => _focused = _focusNode.hasFocus);

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  int get _nearestTick {
    final span = widget.max - widget.min;
    if (span <= 0) return 0;
    final fraction = ((widget.value - widget.min) / span).clamp(0.0, 1.0);
    return (fraction * (widget.ticks!.length - 1)).round();
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
      meterColor: tokens.accentSoft,
      meterFraction: meterFraction,
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
        onChanged: widget.onChanged,
      ),
    );

    // Silent on keyboard focus in the source design, same as the other form
    // controls; this package's own accessibility ring fills the gap.
    final ring = Opacity(
      opacity: widget.muted ? 0.5 : (widget.onChanged == null ? 0.7 : 1),
      child: Container(
        padding: const EdgeInsets.all(focusRingGap),
        decoration: BoxDecoration(
          border: Border.all(
            color: _focused ? tokens.focusRing : Colors.transparent,
            width: focusRingWidth,
          ),
          borderRadius: BorderRadius.circular(AppRadii.full),
        ),
        // On touch the 24px-tall control grows to the touch floor; the track stays centred and looks the same.
        child: AppTouchTargets.of(context)
            ? SizedBox(height: AppSizes.rowTouch, child: slider)
            : slider,
      ),
    );

    return Semantics(
      label: widget.semanticLabel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ring,
          if (widget.ticks != null) ...[
            const SizedBox(height: AppSpacing.s8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < widget.ticks!.length; i++)
                  Text(
                    widget.ticks![i],
                    style: AppText.micro.copyWith(
                      color: i == _nearestTick
                          ? tokens.accent
                          : tokens.textSecondary,
                      fontFamily: AppFonts.mono,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
