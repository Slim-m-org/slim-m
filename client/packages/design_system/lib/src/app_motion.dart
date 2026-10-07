// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Motion, and the one question every animated widget in this system has to
/// ask before it moves anything.
///
/// The design language allows no decorative motion in the chrome. Decision
/// 0004 allows one loop there, the speaking ring; the typing dots and the
/// screen-share loading shape also loop, as content that says something is
/// in progress, and all three stop under reduce-motion. Everything
/// animated routes its duration through [AppMotion.reduced], so honouring the
/// OS setting is one call rather than a policy each widget reinvents.
///
/// Deliberately not covered: a busy spinner. iOS and Android both keep their
/// own activity indicators spinning under reduce-motion, because a frozen
/// spinner reads as a hung app rather than as a calmer one, and matching the
/// platform matters more here than a literal reading of the setting.
library;

import 'package:flutter/widgets.dart';

/// Durations and the reduce-motion signal.
abstract final class AppMotion {
  /// Press and hover micro-feedback. The design language's `duration.fast`.
  static const Duration fast = Duration(milliseconds: 100);

  /// Panel and route transitions. The design language's `duration.base`.
  static const Duration base = Duration(milliseconds: 180);

  /// Modal entrances, and the chrome's ceiling: nothing here runs longer.
  /// The design language's `duration.slow`.
  static const Duration slow = Duration(milliseconds: 280);

  /// The one standard ease-out for entrances, and its accelerating
  /// counterpart for exits, named once so every transition agrees. The
  /// motion spec names these as `Curves.easeOutCubic` / `Curves.easeIn`.
  static const Curve entrance = Curves.easeOutCubic;
  static const Curve exit = Curves.easeIn;

  /// A confirmation pop (a reaction chip, an unread dot): scale .85 to 1
  /// with a fade, enough to confirm the tap landed, no bounce.
  static const Duration pop = Duration(milliseconds: 140);

  /// How far a pressed button may shrink. The spec's own ceiling: "buttons
  /// may add scale(.98) on press - never more".
  static const double pressScale = 0.98;

  /// One direction of the speaking ring's pulse. It reverses, so a full cycle
  /// is twice this; the chrome's 280ms ceiling governs transitions, not a loop.
  static const Duration speakingPulse = Duration(milliseconds: 600);

  /// One full cycle of the typing dots' wave, which loops while someone types.
  static const Duration typingWave = Duration(milliseconds: 900);

  /// Whether this viewer has asked for less motion.
  ///
  /// Two signals rather than one. `disableAnimations` is the OS reduce-motion
  /// switch. `accessibleNavigation` is a screen reader being on, where a loop
  /// is movement nobody sees and a transition is only a delay in front of the
  /// next announcement; Flutter's own material widgets read it the same way.
  static bool isReduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);

  /// [full], or nothing at all when the viewer has asked for less motion.
  ///
  /// Zero rather than merely quick: a 20ms tween is still a tween, and it is
  /// the state change that carries the meaning, never the travel between.
  static Duration reduced(BuildContext context, Duration full) =>
      isReduced(context) ? Duration.zero : full;

  /// [reduced], except an [AnimatedSize] must never actually receive the
  /// zero it returns.
  ///
  /// `RenderAnimatedSize` listens to its own `AnimationController` and calls
  /// `markNeedsLayout` from that listener; a zero-duration controller
  /// completes and notifies synchronously rather than on the next tick, so a
  /// child whose size changes twice before the animation settles re-enters
  /// `markNeedsLayout` on the very `RenderObject` still inside its own
  /// `performLayout`, which Flutter asserts against. `AnimationController`
  /// carries the identical scar: its own `forward()` runs a zero-duration
  /// animation at 5% of its real duration instead, with a comment reading
  /// "the framework cannot handle zero duration animations". One millisecond
  /// is that same fix, sized for this design language's shortest step.
  static Duration reducedSize(BuildContext context, Duration full) =>
      isReduced(context) ? const Duration(milliseconds: 1) : full;
}

/// An install's own override of [AppMotion.isReduced]'s first signal, set
/// from Personal settings rather than only ever inherited from the OS.
///
/// [system] is the default and every existing install's behaviour: nothing
/// changes for someone who has never opened the control. [alwaysReduce] and
/// [neverReduce] let a viewer disagree with their own OS setting - a shared
/// or work device whose accessibility settings are not theirs to change, or
/// someone who wants the pulse and the motion spec's transitions regardless.
enum MotionOverride { system, alwaysReduce, neverReduce }

/// Applies [MotionOverride] to [MediaQueryData.disableAnimations] only.
///
/// [MediaQueryData.accessibleNavigation] (a screen reader) is left untouched
/// in every case, including [MotionOverride.neverReduce]: that flag is a
/// second person's assistive technology being on, not a preference this
/// install's owner is choosing away, so [AppMotion.isReduced] still reduces
/// motion for a screen-reader user who asked this override for the opposite.
MediaQueryData overrideMotion(MediaQueryData data, MotionOverride choice) =>
    switch (choice) {
      MotionOverride.system => data,
      MotionOverride.alwaysReduce => data.copyWith(disableAnimations: true),
      MotionOverride.neverReduce => data.copyWith(disableAnimations: false),
    };
