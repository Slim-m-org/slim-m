// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A form control with its name above it and, optionally, a line of help
/// below.
///
/// [AppInput] draws the box and its own error line but no label, because the
/// source design keeps that outside the control. This is that outside, so
/// every pre-session form names its fields the same way instead of each
/// screen improvising a caption.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
  });

  final String label;
  final Widget child;

  /// One sentence on what the field is for, shown under it. An error the
  /// control itself reports sits between the two.
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.label.copyWith(color: tokens.textSecondary)),
        const SizedBox(height: AppSpacing.s4),
        child,
        if (helper case final helper?) ...[
          const SizedBox(height: AppSpacing.s4),
          Text(
            helper,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ],
    );
  }
}
