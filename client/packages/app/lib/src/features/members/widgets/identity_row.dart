// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One row of Settings > Profile's Identity card.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../settings/widgets/settings_section_header.dart';

/// One `.row` of the Identity card: a lead, a two-line label (caption above
/// value when there is no lead) and trailing actions.
class IdentityRow extends StatelessWidget {
  const IdentityRow({
    super.key,
    required this.title,
    required this.trailing,
    this.leading,
    this.caption,
    this.mono = false,
  });

  final Widget? leading;
  final String title;
  final String? caption;
  final bool mono;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    final captionText = caption == null
        ? null
        : Text(
            caption!,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          );
    final titleText = Text(
      title,
      overflow: TextOverflow.ellipsis,
      style: (mono ? AppText.code : AppText.ui).copyWith(
        color: tokens.textPrimary,
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical,
        ),
        child: Row(
          spacing: AppSpacing.s12,
          children: [
            ?leading,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: leading == null
                    ? [?captionText, titleText]
                    : [titleText, ?captionText],
              ),
            ),
            ...trailing,
          ],
        ),
      ),
    );
  }
}
