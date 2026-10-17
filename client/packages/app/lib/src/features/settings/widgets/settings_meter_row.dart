// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A card row for a measured number: a label, a mono value, and a thin bar
/// under it when the value is a share of something.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsMeterRow extends StatelessWidget {
  const SettingsMeterRow({
    super.key,
    required this.label,
    required this.value,
    this.of,
    this.fraction,
    this.warn = false,
  });

  final String label;
  final String value;

  /// The cap or total the value is read against, e.g. "of 100.0 MB".
  final String? of;

  /// Fill of the bar, 0 to 1; null draws no bar.
  final double? fraction;

  /// Draws the value in the danger colour, for a pool sitting at its ceiling.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final mono = AppText.caption.copyWith(fontFamily: AppFonts.mono);
    return Container(
      constraints: BoxConstraints(minHeight: fraction == null ? 56 : 0),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s16,
        vertical: 14,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: AppSpacing.s12,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              Text.rich(
                TextSpan(
                  text: value,
                  style: mono.copyWith(
                    color: warn ? tokens.dangerText : tokens.textPrimary,
                  ),
                  children: [
                    if (of != null)
                      TextSpan(
                        text: ' $of',
                        style: TextStyle(color: tokens.textSecondary),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (fraction != null) ...[
            const SizedBox(height: AppSpacing.s8),
            _FillBar(fraction: fraction!, warn: warn),
          ],
        ],
      ),
    );
  }
}

/// [used] as a share of [max], clamped to the bar; an empty cap reads as empty.
double meterFraction(num used, num max) =>
    max <= 0 ? 0 : (used / max).clamp(0.0, 1.0).toDouble();

class _FillBar extends StatelessWidget {
  const _FillBar({required this.fraction, required this.warn});

  final double fraction;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.full),
        child: Container(
          height: 4,
          color: tokens.surfaceSunken,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction,
            heightFactor: 1,
            child: ColoredBox(
              color: warn ? tokens.dangerText : tokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
