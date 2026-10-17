// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A labelled form control inside a [SettingsCardBlock]: the design's `.field`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
  });

  final String label;
  final Widget child;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Text(
          label,
          style: AppText.caption.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.medium,
          ),
        ),
        child,
        if (helper case final helper?)
          Text(
            helper,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
  }
}
