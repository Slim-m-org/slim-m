// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two sample messages laid out with the same density tokens a real row uses,
/// so a change shows in the settings pane without leaving it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/widgets/continuation_marker.dart';
import '../../members/widgets/user_avatar.dart';

import '../providers/display_density.dart';

class DisplayDensityPreview extends StatelessWidget {
  const DisplayDensityPreview({
    super.key,
    required this.density,
    required this.groupSpacing,
    this.marker = ContinuationMarker.none,
  });

  final AppDensity density;
  final int groupSpacing;
  final ContinuationMarker marker;

  static const Key firstRowKey = Key('density_preview_first');
  static const Key secondRowKey = Key('density_preview_second');
  static const Key continuationRowKey = Key('density_preview_continuation');

  @override
  Widget build(BuildContext context) {
    final avatar = density.avatarSize;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ColoredBox(
      color: tokens.surfaceBase,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          14,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'PREVIEW',
              style: AppText.micro.copyWith(
                fontFamily: AppFonts.mono,
                letterSpacing: 11 * AppTracking.label,
                color: tokens.textSecondary,
              ),
            ),
            _Sample(
              key: firstRowKey,
              avatar: avatar,
              top: density.rowGap,
              name: 'Ada',
              time: '9:41a',
              line: 'Does the new spacing read better?',
            ),
            _SampleContinuation(
              key: continuationRowKey,
              density: density,
              marker: marker,
              line: 'Same author, a follow-up line.',
            ),
            _Sample(
              key: secondRowKey,
              avatar: avatar,
              top: density.rowGap + groupSpacing,
              name: 'Grace',
              time: '9:42a',
              line: 'It does, a little tighter.',
            ),
          ],
        ),
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
    required this.time,
    required this.line,
  });

  final double avatar;
  final double top;
  final String name;
  final String time;
  final String line;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Sample people with no picture, so the known form skips a profile lookup for an id that does not exist.
          UserAvatar.known(
            name: name,
            userId: 'density-preview-$name',
            avatarUpdatedAt: null,
            size: avatar,
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: name,
                    children: [
                      TextSpan(
                        text: '  $time',
                        style: AppText.micro.copyWith(
                          fontFamily: AppFonts.mono,
                          fontWeight: AppWeights.regular,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  style: AppText.ui.copyWith(
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

class _SampleContinuation extends StatelessWidget {
  const _SampleContinuation({
    super.key,
    required this.density,
    required this.marker,
    required this.line,
  });

  final AppDensity density;
  final ContinuationMarker marker;
  final String line;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Stack(
      children: [
        if (marker != ContinuationMarker.none)
          ContinuationRail(
            marker: marker,
            geometry: ContinuationGeometry.of(
              context,
              gutter: 0,
              density: density,
            ),
            lastInGroup: true,
          ),
        Padding(
          padding: EdgeInsets.only(
            top: density.groupedRowGap,
            left: density.avatarSize + AppSpacing.s12,
          ),
          child: Text(
            line,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ),
      ],
    );
  }
}
