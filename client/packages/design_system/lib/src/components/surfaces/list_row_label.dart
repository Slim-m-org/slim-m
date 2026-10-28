// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';

/// The label, with an optional one-line subtitle (and a small icon before it)
/// under it, split out of [AppListRow] to keep that file under its budget.
class AppListRowLabel extends StatelessWidget {
  const AppListRowLabel({
    required this.label,
    required this.labelStyle,
    this.subtitle,
    this.subtitleIcon,
    super.key,
  });

  final String label;
  final String? subtitle;
  final IconData? subtitleIcon;
  final TextStyle labelStyle;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: labelStyle,
    );
    final subtitle = this.subtitle;
    if (subtitle == null) return text;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        text,
        Row(
          children: [
            if (subtitleIcon != null) ...[
              Icon(subtitleIcon, size: 12, color: tokens.textSecondary),
              const SizedBox(width: AppSpacing.s4),
            ],
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
