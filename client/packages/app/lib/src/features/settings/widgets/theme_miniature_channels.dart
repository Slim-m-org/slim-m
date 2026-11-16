// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The miniature's channel list: the Space's name, then the channels, the
/// first selected; a large text size cuts it at the bottom like the chat.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeMiniatureChannels extends StatelessWidget {
  const ThemeMiniatureChannels({
    super.key,
    required this.tokens,
    required this.width,
    required this.channels,
    this.space,
    this.muted,
  });

  final AppTokens tokens;
  final double width;

  /// The Space's name over the channels, as the app's own list has it.
  final String? space;

  /// The first is the selected channel.
  final List<String> channels;
  final String? muted;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border(right: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4,
          vertical: AppSpacing.s8,
        ),
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                if (space case final space?) _space(space),
                for (final (i, name) in channels.indexed)
                  _channel(name, selected: i == 0, muted: name == muted),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _space(String name) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.s8,
      AppSpacing.s4,
      AppSpacing.s8,
      AppSpacing.s8,
    ),
    child: Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppText.caption.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.semi,
      ),
    ),
  );

  Widget _channel(String name, {required bool selected, required bool muted}) {
    final colour = selected
        ? tokens.textPrimary
        : muted
        ? tokens.textDisabled
        : tokens.textSecondary;
    return SizedBox(
      height: AppSizes.rowPointer,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? tokens.accentSoft : null,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            if (selected)
              Positioned(
                left: 0,
                top: 6,
                bottom: 6,
                width: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Row(
                spacing: AppSpacing.s4,
                children: [
                  Icon(AppIcons.hash, size: AppSizes.icon16, color: colour),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.ui.copyWith(color: colour),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
