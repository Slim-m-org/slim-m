// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A labelled slider for a settings card: the label with its value in mono at
/// the right, the track, and the range ends in mono underneath.
///
/// In a [SettingsControlColumn] the track and its value take the column at
/// the card's right inset, with the ends flush under the track; below the
/// column's width the row stacks and the track spans it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_control_column.dart';
import 'settings_search.dart';

class SettingsSliderRow extends StatelessWidget {
  const SettingsSliderRow({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.minLabel,
    required this.maxLabel,
    required this.onChanged,
    this.divisions,
    this.sliderKey,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final String minLabel;
  final String maxLabel;
  final int? divisions;
  final Key? sliderKey;
  final ValueChanged<double> onChanged;

  /// The least room the value keeps beside the track, so the track does not
  /// change length as the value does.
  static const valueMinWidth = 48.0;

  static const _inset = AppSpacing.s16;
  static const _top = AppSpacing.s12;
  static const _bottom = 14.0;

  @override
  Widget build(BuildContext context) =>
      SettingsHighlightTarget(label: label, child: _content(context));

  Widget _content(BuildContext context) {
    final parts = _Parts(this, Theme.of(context).extension<AppTokens>()!);
    final column = SettingsControlColumn.widthOf(context);
    if (column == null) return _stacked(parts, flush: false);
    return LayoutBuilder(
      builder: (context, box) => SettingsControlColumn.besideAt(box.maxWidth)
          ? _beside(context, parts, column)
          : _stacked(parts, flush: true),
    );
  }

  /// The label and value above the track; [flush] runs the track to the
  /// row's insets with the ends under its ends.
  Widget _stacked(_Parts parts, {required bool flush}) {
    final sliderInset = flush
        ? math.max(0.0, _inset - AppSlider.trackInset)
        : _inset;
    final endsInset = flush ? _inset : _inset + AppSpacing.s8;
    return Padding(
      padding: const EdgeInsets.only(top: _top, bottom: _bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: _inset),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: parts.label),
                parts.value(),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: sliderInset),
            child: parts.slider,
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: endsInset),
            child: parts.ends,
          ),
        ],
      ),
    );
  }

  /// The label at the left; the track and its value in [column] at the right
  /// inset, the ends under the track.
  Widget _beside(BuildContext context, _Parts parts, double column) {
    final valueWidth = math.max(valueMinWidth, parts.valueWidth(context));
    Widget control(Widget track, [Widget? value]) => SizedBox(
      width: column + AppSlider.trackInset,
      child: Row(
        children: [
          Expanded(child: track),
          SizedBox(width: valueWidth, child: value),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(_inset, _top, _inset, _bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: parts.label),
              control(parts.slider, parts.value()),
            ],
          ),
          Row(
            children: [
              const Spacer(),
              control(
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSlider.trackInset,
                  ),
                  child: parts.ends,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The pieces both layouts arrange.
class _Parts {
  _Parts(this.row, this.tokens)
    : _mono = AppText.micro.copyWith(
        fontFamily: AppFonts.mono,
        color: tokens.textSecondary,
      );

  final SettingsSliderRow row;
  final AppTokens tokens;
  final TextStyle _mono;

  Widget get label =>
      Text(row.label, style: AppText.ui.copyWith(color: tokens.textPrimary));

  TextStyle get _valueStyle =>
      _mono.copyWith(fontSize: AppText.caption.fontSize);

  Widget value() => Text(
    row.valueLabel,
    maxLines: 1,
    softWrap: false,
    textAlign: TextAlign.right,
    style: _valueStyle,
  );

  /// The value's drawn width at this text scale.
  double valueWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: row.valueLabel,
        style: DefaultTextStyle.of(context).style.merge(_valueStyle),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width.ceilToDouble();
  }

  Widget get slider => AppSlider(
    key: row.sliderKey,
    value: row.value,
    min: row.min,
    max: row.max,
    divisions: row.divisions,
    semanticLabel: row.label,
    onChanged: row.onChanged,
  );

  Widget get ends => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(row.minLabel, style: _mono),
      Text(row.maxLabel, style: _mono),
    ],
  );
}
