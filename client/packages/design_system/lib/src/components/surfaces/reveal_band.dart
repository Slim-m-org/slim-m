// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One shape for every band that appears above or below something stable: a
/// reply strip, a search bar, an inline error, a row of staged attachments.
///
/// Each of those used to pop in fully formed and vanish in one frame; this
/// grows the band open (height through [AnimatedSize], content through
/// [AppFadeIn]) and retracts it the same way when [child] goes null. The
/// retracted placeholder keeps the full width at zero height, so the reveal
/// reads as the band unfolding rather than wiping in from a corner.
///
/// This is for bands beside stable content, never list rows: row height is
/// layout, not motion, per the motion spec's own rule.
library;

import 'package:flutter/widgets.dart';

import '../../app_fade_in.dart';
import '../../app_motion.dart';

class AppRevealBand extends StatelessWidget {
  const AppRevealBand({super.key, this.child});

  /// The band, or null while there is nothing to show.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    const retracted = SizedBox(width: double.infinity, height: 0);
    return MaybeAnimatedSize(
      duration: AppMotion.base,
      curve: AppMotion.entrance,
      alignment: Alignment.topCenter,
      child: child == null ? retracted : AppFadeIn(child: child!),
    );
  }
}

/// [AnimatedSize] that honours reduce-motion by not existing: a size change
/// then lands in one frame, exactly as if the wrapper were never there.
///
/// [AppMotion.reduced]'s usual zero-duration answer is wrong for this one
/// widget: a zero-duration [AnimatedSize] completes inside its own layout
/// pass, notifying listeners that mark it dirty mid-layout, which trips
/// RenderAnimatedSize's no-mutation-during-performLayout assertion.
class MaybeAnimatedSize extends StatelessWidget {
  const MaybeAnimatedSize({
    super.key,
    required this.duration,
    required this.curve,
    this.alignment = Alignment.center,
    required this.child,
  });

  final Duration duration;
  final Curve curve;
  final Alignment alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: AppMotion.reducedSize(context, duration),
      curve: curve,
      alignment: alignment,
      child: child,
    );
  }
}
