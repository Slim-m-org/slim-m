// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone card's level meter: the live input level as a bar, the gate
/// threshold as a line across it, and a plain statement of what is happening
/// to the sound. The line is draggable by hand and read-only while automatic.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show inputLevelFraction, kInputFloorDb;

/// What the gate is doing with the sound right now.
enum InputLevelStatus {
  waiting('No signal yet'),
  muted('Muted'),
  notSent('Below the line, not sent'),
  sending('Sending');

  const InputLevelStatus(this.label);

  final String label;
}

/// Finds the meter in tests.
const inputLevelMeterKey = ValueKey('input-level-meter');

class InputLevelMeter extends StatelessWidget {
  const InputLevelMeter({
    super.key,
    required this.thresholdDb,
    required this.status,
    required this.onChanged,
    this.levelDb,
    this.auto = false,
    this.semanticLabel = 'Input sensitivity',
  });

  final double thresholdDb;
  final InputLevelStatus status;

  /// Null makes the line read-only, as it is while [auto] moves it.
  final ValueChanged<double>? onChanged;

  /// Null until a reading has arrived.
  final double? levelDb;

  /// The line is placed by automatic sensitivity, not by the member.
  final bool auto;
  final String semanticLabel;

  static const _barHeight = 14.0;
  static const _hitHeight = 32.0;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final line = '${thresholdDb.round()} dB';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.s8,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Input sensitivity',
                style: AppText.ui.copyWith(color: tokens.textPrimary),
              ),
            ),
            _StatusLabel(status: status),
          ],
        ),
        _bar(context, tokens),
        Text(
          auto
              ? 'Automatic: the line follows your room, now at $line.'
              : 'Line at $line. Drag it to change.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      ],
    );
  }

  Widget _bar(BuildContext context, AppTokens tokens) {
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        final lineX = inputLevelFraction(thresholdDb) * width;
        void dragTo(double dx) {
          final change = onChanged;
          if (change == null || width <= 0) return;
          final db = kInputFloorDb - kInputFloorDb * (dx / width);
          change(db.clamp(kInputFloorDb, 0.0).roundToDouble());
        }

        void nudge(double db) => onChanged?.call(
          (thresholdDb + db).clamp(kInputFloorDb, 0.0).roundToDouble(),
        );

        return Semantics(
          label: semanticLabel,
          value: auto
              ? 'Automatic, ${thresholdDb.round()} dB'
              : '${thresholdDb.round()} dB',
          slider: true,
          increasedValue: '${(thresholdDb + 1).round()} dB',
          decreasedValue: '${(thresholdDb - 1).round()} dB',
          onIncrease: onChanged == null ? null : () => nudge(1),
          onDecrease: onChanged == null ? null : () => nudge(-1),
          child: ExcludeSemantics(
            child: Focus(
              canRequestFocus: onChanged != null,
              onKeyEvent: (_, event) {
                if (event is KeyUpEvent || onChanged == null) {
                  return KeyEventResult.ignored;
                }
                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.arrowRight ||
                    key == LogicalKeyboardKey.arrowUp) {
                  nudge(1);
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowLeft ||
                    key == LogicalKeyboardKey.arrowDown) {
                  nudge(-1);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => dragTo(d.localPosition.dx),
                onHorizontalDragUpdate: (d) => dragTo(d.localPosition.dx),
                child: SizedBox(
                  height: _hitHeight,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      _Track(
                        width: width,
                        lineX: lineX,
                        levelDb: levelDb,
                        dimmed: status == InputLevelStatus.muted,
                      ),
                      AnimatedPositioned(
                        duration: AppMotion.fast,
                        curve: Curves.easeOut,
                        left: lineX - 2,
                        top: 0,
                        bottom: 0,
                        child: Container(
                          key: const ValueKey('input-threshold-line'),
                          width: 4,
                          decoration: BoxDecoration(
                            color: auto
                                ? tokens.textSecondary
                                : tokens.textPrimary,
                            borderRadius: BorderRadius.circular(2),
                            border: Border.all(color: tokens.surfaceBase),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The trough and the level in it: neutral up to the line, accent past it.
class _Track extends StatelessWidget {
  const _Track({
    required this.width,
    required this.lineX,
    required this.levelDb,
    required this.dimmed,
  });

  final double width;
  final double lineX;
  final double? levelDb;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final levelX = levelDb == null ? 0.0 : inputLevelFraction(levelDb!) * width;
    final below = levelX < lineX ? levelX : lineX;
    final above = levelX > lineX ? levelX - lineX : 0.0;
    final opacity = dimmed ? 0.4 : 1.0;
    return Container(
      height: InputLevelMeter._barHeight,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: tokens.borderSubtle),
      ),
      child: Opacity(
        opacity: opacity,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              width: below,
              top: 0,
              bottom: 0,
              child: ColoredBox(
                key: const ValueKey('input-level-below'),
                color: tokens.textDisabled,
              ),
            ),
            Positioned(
              left: lineX,
              width: above,
              top: 0,
              bottom: 0,
              child: ColoredBox(
                key: const ValueKey('input-level-above'),
                color: tokens.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.status});

  final InputLevelStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final sending = status == InputLevelStatus.sending;
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: sending ? tokens.accent : tokens.textDisabled,
          ),
        ),
        Text(
          status.label,
          style: AppText.caption.copyWith(
            color: sending ? tokens.textPrimary : tokens.textSecondary,
          ),
        ),
      ],
    );
  }
}
