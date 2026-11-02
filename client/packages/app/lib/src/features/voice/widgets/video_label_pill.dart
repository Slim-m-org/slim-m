// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The translucent pill that keeps a name readable when it sits on live video.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The pill itself, for tests to find.
const videoLabelPillKey = ValueKey('video-label-pill');

/// Backs [child] with the same pill `MediaLabelChip` uses, so white or dark
/// text stays legible over any frame, light or dark.
class VideoLabelPill extends StatelessWidget {
  const VideoLabelPill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      key: videoLabelPillKey,
      decoration: BoxDecoration(
        color: tokens.surfaceBase.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadii.full),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: 2,
        ),
        child: child,
      ),
    );
  }
}
