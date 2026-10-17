// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The frame every pre-session screen sits in: a brand panel on the left, the
/// step you are on to the right of it.
///
/// The shape is an installer's, deliberately. Getting into a self-hosted Space
/// is genuinely several decisions - which server, is it the right server, who
/// are you on it - and the previous single centred card gave no sense of how
/// many were left or which one you were in. A fixed panel plus a numbered
/// stepper answers both without a word of copy.
///
/// The panel is chrome, so it goes first when there is no room: below
/// [_panelFloor] it collapses to the mark and the wordmark above the content,
/// because a phone needs the whole width for the form and the pitch is not
/// what somebody halfway through signing in came for.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

export 'server_identity_chip.dart';

/// Narrowest width that still gets the brand panel. Above this there is room
/// for a 260px brand rail and a 440px form with gutters; below it, there is not.
const double _panelFloor = 900;

/// Height past which the top-biased alignment below stops and centering
/// starts.
///
/// The bias reads as "starting near the top with room to grow" on an
/// ordinary desktop window, but the gap it leaves below the content grows
/// with the window, not with the content: past this height it read as a
/// filled top 60% and an empty bottom 40% rather than a screen with room to
/// spare. Centering fixes the balance without touching the shorter case,
/// where the same math never produced enough leftover space to notice.
const double _tallWindowFloor = 900;

/// One step in the join flow, and how far along it the caller is.
///
/// Numbered rather than named-only because the number is the part that says
/// "two more after this", which is the whole reason the stepper is here.
///
/// Two members, not three: confirming a server's identity is a conditional
/// security check, not a counted step, since it fires once, more than once,
/// or not at all depending on what is already pinned for that address.
/// `server_fingerprint_step.dart` and `server_identity_changed_step.dart`
/// render it outside this shell for exactly that reason. An earlier third
/// member, `server`, was never passed by any production widget and is
/// removed rather than left dead.
enum OnboardingStep {
  invite('invite'),
  identity('who are you');

  const OnboardingStep(this.label);

  final String label;
}

class OnboardingShell extends StatelessWidget {
  const OnboardingShell({
    super.key,
    required this.child,
    this.step,
    this.version,
  });

  final Widget child;

  /// The running build, shown at the foot of the brand rail, or null while it
  /// is still being read. A version on the screen a tester first meets is the
  /// difference between a bug report that can be placed and one that cannot.
  final String? version;

  /// The step being shown, or null for a screen that is not part of the join
  /// flow - signing back in to a server you already trust is one act, and a
  /// "step 1 of 1" would be furniture.
  final OnboardingStep? step;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final wide = MediaQuery.sizeOf(context).width >= _panelFloor;
    final tall = MediaQuery.sizeOf(context).height >= _tallWindowFloor;

    final content = AnimatedAlign(
      // Top-ish with room; centred on a phone or once the window is tall.
      alignment: !wide || tall ? Alignment.center : const Alignment(0, -0.55),
      duration: AppMotion.reduced(context, AppMotion.base),
      curve: AppMotion.entrance,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!wide) ...[
              const _Wordmark(compact: true),
              const SizedBox(height: AppSpacing.s24),
            ],
            Center(
              child: ConstrainedBox(
                // Wider than the form so the step labels have room.
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // A band, not a hard cut: sign-in grows this in place when "create account" opens.
                    AppRevealBand(
                      child: step == null
                          ? null
                          : Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpacing.s32,
                              ),
                              child: OnboardingStepper(current: step!),
                            ),
                    ),
                    child,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (!wide) {
      return Scaffold(body: SafeArea(child: content));
    }

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            Container(
              // A slim brand rail, not a third of the viewport; see [_BrandPanel].
              width: 260,
              decoration: BoxDecoration(
                color: tokens.surfaceSunken,
                border: Border(right: BorderSide(color: tokens.borderSubtle)),
              ),
              child: _BrandPanel(version: version),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

/// The mark beside the wordmark, in mono at the design's own tracking.
class _Wordmark extends StatelessWidget {
  const _Wordmark({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      mainAxisAlignment: compact
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        AppBrandMark(size: compact ? 24 : 30),
        const SizedBox(width: AppSpacing.s12),
        Text(
          'slim-m',
          style: AppText.heading.copyWith(
            color: tokens.textPrimary,
            fontFamily: AppFonts.mono,
            fontWeight: AppWeights.medium,
            letterSpacing: 20 * 0.04,
          ),
        ),
      ],
    );
  }
}

/// The left column: the mark, the mark's own lattice drawn large behind it,
/// and the build number at the foot.
///
/// Still no copy below the wordmark, on purpose. It once carried a headline,
/// a subtitle and three promises, and most of it was either marketing or not
/// true yet; copy that overstates what a self-hosted server does is worse here
/// than nowhere, because this is the screen where somebody decides whether to
/// trust one. What replaced the blank is [AppBrandLattice], which is the
/// brand's one figure and cannot promise anything - it turned a rail that read
/// as an unfinished half into one that reads as designed.
///
/// The version is the one line of text allowed in, because it is a fact a
/// tester needs and this is the first screen they see.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel({this.version});

  final String? version;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Stack(
      fit: StackFit.expand,
      children: [
        const AppBrandLattice(),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Wordmark(),
              const Spacer(),
              if (version case final v?)
                Text(
                  'v$v',
                  style: AppText.code.copyWith(color: tokens.textSecondary),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `1 invite - 2 who are you`.
///
/// Every step is always shown, including the ones behind you: the point is to
/// say how many there are, and a stepper that only counts forwards cannot.
/// Steps already passed are ticked rather than numbered, so "done" and "still
/// to come" differ in shape and not only in colour.
class OnboardingStepper extends StatelessWidget {
  const OnboardingStepper({super.key, required this.current});

  final OnboardingStep current;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final steps = OnboardingStep.values;

    return Semantics(
      container: true,
      label: 'Step ${current.index + 1} of ${steps.length}: ${current.label}',
      child: ExcludeSemantics(
        // Under ~420px only the current step keeps its words; the count stays.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final labelled = constraints.maxWidth >= 420;
            return Row(
              children: [
                for (final (i, step) in steps.indexed) ...[
                  // Fixed, not Expanded: stretching truncated the longest label.
                  if (i > 0)
                    Container(
                      width: 24,
                      height: 1,
                      margin: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s8,
                      ),
                      color: tokens.borderSubtle,
                    ),
                  // Loose flex: flex 0 reads as non-flex and constrains nothing.
                  Flexible(
                    child: _Pip(
                      index: i,
                      label: labelled || step == current ? step.label : null,
                      done: i < current.index,
                      active: step == current,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Pip extends StatelessWidget {
  const _Pip({
    required this.index,
    required this.label,
    required this.done,
    required this.active,
  });

  final int index;

  /// Null where there is no room for words; the pip keeps its number.
  final String? label;

  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final lit = done || active;
    final diameter = MediaQuery.textScalerOf(context).scale(20);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: ValueKey('onboarding_pip_$index'),
          width: diameter,
          height: diameter,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? tokens.accentSoft : Colors.transparent,
            border: Border.all(
              color: lit ? tokens.accent : tokens.borderSubtle,
            ),
          ),
          child: done
              ? Icon(
                  AppIcons.check,
                  size: MediaQuery.textScalerOf(context).scale(11),
                  color: tokens.accent,
                )
              : Text(
                  '${index + 1}',
                  style: AppText.code.copyWith(
                    fontSize: AppText.micro.fontSize,
                    color: lit ? tokens.accent : tokens.textSecondary,
                  ),
                ),
        ),
        if (label != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label!,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                color: lit ? tokens.textPrimary : tokens.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
