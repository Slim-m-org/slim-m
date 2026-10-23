// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A slot's progress node: a bar with its label and value always in text.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

const double _barHeight = 6;

/// Whole numbers without a decimal point, anything else to one place.
String formatSlotNumber(double value) {
  if (value == value.roundToDouble()) return value.round().toString();
  return value.toStringAsFixed(1);
}

class ModuleSlotProgressBar extends StatelessWidget {
  const ModuleSlotProgressBar(this.node, {super.key});

  final api.ModuleSlotProgress node;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final amount =
        '${formatSlotNumber(node.value)} / ${formatSlotNumber(node.max)}';
    final fraction = node.max <= 0 ? 0.0 : node.value / node.max;
    final label = node.label;
    return Semantics(
      container: true,
      label: label,
      value: '${formatSlotNumber(node.value)} of ${formatSlotNumber(node.max)}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              spacing: AppSpacing.s8,
              children: [
                if (label != null)
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textPrimary,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                Text(
                  amount,
                  maxLines: 1,
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.full),
              child: SizedBox(
                height: _barHeight,
                child: ColoredBox(
                  color: tokens.borderSubtle,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: fraction.clamp(0.0, 1.0),
                      child: ColoredBox(
                        color: tokens.accentFill,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
