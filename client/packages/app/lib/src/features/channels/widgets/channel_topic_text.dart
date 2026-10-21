// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-line channel topic in a header, readable in full on demand.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Hover shows the whole topic in a tooltip; a tap opens it in `showAppSheet`
/// (desktop-vs-mobile rule 3: a sheet on touch, a dialog from 600 wide).
class ChannelTopicText extends StatelessWidget {
  const ChannelTopicText({super.key, required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    // Left-aligned so the hit area is the text's own width, not the space after it.
    return Align(
      alignment: Alignment.centerLeft,
      child: AppTouchHitArea(
        child: FocusableTapTarget(
          semanticLabel: topic,
          ringRadius: AppRadii.control,
          onTap: () => _showFullTopic(context),
          builder: (context, focused, hovered) {
            final text = Text(
              topic,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            );
            return touch ? text : Tooltip(message: topic, child: text);
          },
        ),
      ),
    );
  }

  void _showFullTopic(BuildContext context) {
    showAppSheet<void>(
      context,
      builder: (context) {
        final tokens = Theme.of(context).extension<AppTokens>()!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s16,
          ),
          child: SelectableText(
            topic,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        );
      },
    );
  }
}
