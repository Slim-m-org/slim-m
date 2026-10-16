// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An on/off switch. State is never colour alone: the thumb moves between
/// two fixed positions and the track only fills when on, so position and
/// fill carry the state together with the accent hue rather than instead
/// of it.
///
/// `locked` is a distinct concept from a plain disabled control: it means
/// on and deliberately not user-changeable, for a redundant accessibility
/// cue that must not be switched off. It reports as on (never as off or
/// indeterminate) and dims to the design's own 0.6 opacity rather than
/// swapping to the disabled-token set a plain non-interactive toggle would.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_motion.dart';
import '../../app_tokens.dart';
import 'focusable_tap_target.dart';

class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    this.onChanged,
    this.locked = false,
    this.focusNode,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool locked;
  final FocusNode? focusNode;
  final String? semanticLabel;

  /// Exact design constants (track 40x22, thumb 16 on and 14 off, padding 2),
  /// not derived from spacing tokens: AppSizes has no switch metric and these
  /// do not sum cleanly from AppSpacing steps.
  static const double _trackWidth = 40;
  static const double _trackHeight = 22;
  static const double _thumbOn = 16;
  static const double _thumbOff = 14;
  static const double _thumbInset = 2;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final interactive = !locked && onChanged != null;

    return Opacity(
      opacity: locked ? 0.6 : 1,
      child: FocusableTapTarget(
        focusNode: focusNode,
        enabled: interactive,
        isButton: false,
        onTap: () => onChanged?.call(!value),
        toggled: value,
        semanticLabel: semanticLabel,
        ringRadius: AppRadii.full,
        builder: (context, focused, hovered) {
          // On is a solid accent track, off a hollow one, per the settings redesign (2026-10-16).
          final trackColor = value ? tokens.accentFill : tokens.surfaceSunken;
          final trackBorder = value ? tokens.accentFill : tokens.borderStrong;
          final thumbColor = value ? tokens.accentOn : tokens.textSecondary;
          final thumb = value ? _thumbOn : _thumbOff;
          final motion =
              AppMotion.reduced(context, const Duration(milliseconds: 150));

          return Container(
            width: _trackWidth,
            height: _trackHeight,
            padding: const EdgeInsets.all(_thumbInset),
            decoration: BoxDecoration(
              color: trackColor,
              borderRadius: BorderRadius.circular(AppRadii.full),
              border: Border.all(color: trackBorder),
            ),
            child: AnimatedAlign(
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              duration: motion,
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: motion,
                curve: Curves.easeOut,
                width: thumb,
                height: thumb,
                margin: EdgeInsets.all((_thumbOn - thumb) / 2),
                decoration:
                    BoxDecoration(color: thumbColor, shape: BoxShape.circle),
              ),
            ),
          );
        },
      ),
    );
  }
}
