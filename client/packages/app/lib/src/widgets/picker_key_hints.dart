// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The keys a keyboard-driven picker answers to, under its list on a pointer.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class PickerKeyHints extends StatelessWidget {
  const PickerKeyHints({super.key, required this.enterLabel});

  /// What Enter does to the highlighted row.
  final String enterLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.caption.copyWith(color: tokens.textSecondary);
    Widget hint(List<String> keys, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s4,
      children: [
        for (final key in keys) AppKbd(key),
        Text(label, style: style),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s16),
      child: Wrap(
        spacing: AppSpacing.s16,
        children: [
          hint(const ['↑', '↓'], 'Move'),
          hint(const ['Enter'], enterLabel),
        ],
      ),
    );
  }
}
