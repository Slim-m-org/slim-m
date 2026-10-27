// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A size slider inside a control's options menu, with a dot that previews
/// the value, for choices that are a quantity rather than a pick.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'control_swatch_row.dart';

/// A [heading] over a slider from [min] to [max] in whole [step]s.
class ControlSliderGroup extends ControlOptionEntry {
  const ControlSliderGroup({
    required this.heading,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.previewColor,
    required this.onChanged,
    this.step = 1,
  });

  final String heading;
  final double value;
  final double min;
  final double max;
  final double step;

  /// Said after the number, e.g. "px".
  final String unit;

  /// The dot that previews the value is drawn in this colour, at the value's own size.
  final Color previewColor;
  final ValueChanged<double> onChanged;
}

class ControlSliderRow extends StatefulWidget {
  const ControlSliderRow({super.key, required this.group});

  final ControlSliderGroup group;

  @override
  State<ControlSliderRow> createState() => _ControlSliderRowState();
}

class _ControlSliderRowState extends State<ControlSliderRow> {
  late double _value = widget.group.value;

  void _change(double next) {
    final step = widget.group.step;
    final snapped = (next / step).round() * step;
    if (snapped == _value) return;
    setState(() => _value = snapped);
    widget.group.onChanged(snapped);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final group = widget.group;
    final height = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.rowPointer;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Row(
        children: [
          SizedBox.square(
            dimension: group.max,
            child: Center(
              child: ExcludeSemantics(
                child: Container(
                  key: const ValueKey('control-slider-preview'),
                  width: _value,
                  height: _value,
                  decoration: BoxDecoration(
                    color: group.previewColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: AppSlider(
              value: _value,
              min: group.min,
              max: group.max,
              divisions: ((group.max - group.min) / group.step).round(),
              keyStep: group.step,
              semanticLabel: group.heading,
              valueLabel: (v) => '${v.round()} ${group.unit}',
              valueBubble: false,
              onChanged: _change,
            ),
          ),
          ExcludeSemantics(
            child: SizedBox(
              width: AppSizes.controlMd,
              child: Text(
                '${_value.round()} ${group.unit}',
                maxLines: 1,
                textAlign: TextAlign.end,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
