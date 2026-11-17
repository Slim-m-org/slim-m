// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A labelled slider for a settings card: the label with its value in mono at
/// the right, the track, and the range ends in mono flush under it, less the
/// end the value sits on.
///
/// The track spans the row's insets; in a [SettingsControlColumn] at least
/// the column's width wide, it takes the column at the card's right inset.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  static const _inset = AppSpacing.s16;
  static const _top = AppSpacing.s12;
  static const _bottom = 14.0;

  @override
  Widget build(BuildContext context) =>
      SettingsHighlightTarget(label: label, child: _content(context));

  Widget _content(BuildContext context) {
    final parts = _Parts(this, Theme.of(context).extension<AppTokens>()!);
    final column = SettingsControlColumn.widthOf(context);
    if (column == null) return _layout(parts, trackLeft: _inset);
    return LayoutBuilder(
      builder: (context, box) => _layout(
        parts,
        trackLeft: SettingsControlColumn.besideAt(box.maxWidth)
            ? box.maxWidth - _inset - column
            : _inset,
      ),
    );
  }

  /// The label and value across the row, then the track from [trackLeft] to
  /// the right inset with its ends flush under it.
  Widget _layout(_Parts parts, {required double trackLeft}) => Padding(
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
              parts.value,
            ],
          ),
        ),
        _TouchReach(
          child: Padding(
            padding: EdgeInsets.only(
              left: math.max(0, trackLeft - AppSlider.trackInset),
              right: math.max(0, _inset - AppSlider.trackInset),
            ),
            child: parts.slider,
          ),
        ),
        // The ends lie inside the track's touch reach, so a press there must fall through to it.
        IgnorePointer(
          child: Padding(
            padding: EdgeInsets.only(left: trackLeft, right: _inset),
            child: parts.ends,
          ),
        ),
      ],
    ),
  );
}

/// The pieces the layout arranges.
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

  Widget get value => Text(
    row.valueLabel,
    maxLines: 1,
    softWrap: false,
    textAlign: TextAlign.right,
    style: _mono.copyWith(fontSize: AppText.caption.fontSize),
  );

  /// Held at pointer height on a phone too, so the ends sit just under the
  /// track; [_TouchReach] gives a finger the touch floor instead.
  Widget get slider => AppTouchTargets(
    enabled: false,
    child: AppSlider(
      key: row.sliderKey,
      value: row.value,
      min: row.min,
      max: row.max,
      divisions: row.divisions,
      semanticLabel: row.label,
      onChanged: row.onChanged,
    ),
  );

  Widget get ends => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      _end(row.minLabel, at: row.value <= row.min),
      _end(row.maxLabel, at: row.value >= row.max),
    ],
  );

  /// An end the value sits on keeps its place unseen: the value says it.
  Widget _end(String label, {required bool at}) => Visibility(
    visible: !at,
    maintainSize: true,
    maintainAnimation: true,
    maintainState: true,
    child: Text(label, style: _mono),
  );
}

/// At touch density, takes a press anywhere in an [AppSizes.rowTouch] band
/// around the slider and hands it to the slider's middle at the same x.
class _TouchReach extends SingleChildRenderObjectWidget {
  const _TouchReach({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTouchReach(touch: AppTouchTargets.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderTouchReach renderObject,
  ) => renderObject.touch = AppTouchTargets.of(context);
}

class _RenderTouchReach extends RenderProxyBox {
  _RenderTouchReach({required this.touch});

  bool touch;

  /// A translation, not a point, so a drag keeps its x and its deltas.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (!touch || child == null) {
      return super.hitTest(result, position: position);
    }
    final spare = math.max(0.0, (AppSizes.rowTouch - size.height) / 2);
    final band = Rect.fromLTRB(0, -spare, size.width, size.height + spare);
    if (!band.contains(position)) return false;
    return result.addWithPaintOffset(
      offset: Offset(0, position.dy - size.height / 2),
      position: position,
      hitTest: (result, position) => child.hitTest(result, position: position),
    );
  }
}
