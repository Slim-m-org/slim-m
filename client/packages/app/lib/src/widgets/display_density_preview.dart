// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two sample messages laid out with the same density tokens a real row uses,
/// so a change shows in the settings pane without leaving it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_density.dart';

class DisplayDensityPreview extends StatelessWidget {
  const DisplayDensityPreview({
    super.key,
    required this.density,
    required this.groupSpacing,
  });

  final AppDensity density;
  final int groupSpacing;

  static const Key firstRowKey = Key('density_preview_first');
  static const Key secondRowKey = Key('density_preview_second');

  @override
  Widget build(BuildContext context) {
    final avatar = density.avatarSize;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sample(
            key: firstRowKey,
            avatar: avatar,
            top: density.rowGap,
            name: 'Ada',
            line: 'Does the new spacing read better?',
          ),
          _Sample(
            key: secondRowKey,
            avatar: avatar,
            top: density.rowGap + groupSpacing,
            name: 'Grace',
            line: 'It does, a little tighter.',
          ),
        ],
      ),
    );
  }
}

class _Sample extends StatelessWidget {
  const _Sample({
    super.key,
    required this.avatar,
    required this.top,
    required this.name,
    required this.line,
  });

  final double avatar;
  final double top;
  final String name;
  final String line;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(name: name, size: avatar),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: AppText.body.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                Text(
                  line,
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
