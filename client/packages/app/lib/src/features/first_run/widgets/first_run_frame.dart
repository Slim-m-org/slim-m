// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The chrome around one setup step: a full-screen page below the compact
/// width, a centred card over the dimmed shell above it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Wide enough for a device picker row, narrow enough to read as a card.
const double kFirstRunCardWidth = 520;

class FirstRunFrame extends StatelessWidget {
  const FirstRunFrame({
    super.key,
    required this.step,
    required this.stepCount,
    required this.title,
    required this.body,
    required this.onContinue,
    required this.onSkip,
    this.subtitle,
    this.onBack,
    this.continueLabel = 'Continue',
    this.busy = false,
    this.continueFocus,
    this.error,
  });

  final int step;
  final int stepCount;
  final String title;
  final String? subtitle;
  final Widget body;
  final VoidCallback onContinue;
  final VoidCallback onSkip;
  final VoidCallback? onBack;
  final String continueLabel;
  final bool busy;
  final FocusNode? continueFocus;

  /// Why the last save was refused, shown above the actions until the next try.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final page = FocusTraversalGroup(
      child: Column(
        mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(tokens, compact),
          // Tight on a phone so the actions sit on the bottom edge.
          Flexible(
            fit: compact ? FlexFit.tight : FlexFit.loose,
            child: _scrollingBody(tokens, compact),
          ),
          _actions(tokens, compact),
        ],
      ),
    );
    if (compact) {
      return Material(
        color: tokens.surfaceBase,
        child: SafeArea(child: page),
      );
    }
    return ColoredBox(
      color: Colors.black54,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: kFirstRunCardWidth,
            maxHeight: 680,
          ),
          child: Material(
            color: tokens.surfaceRaised,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.card),
              side: BorderSide(color: tokens.borderSubtle),
            ),
            clipBehavior: Clip.antiAlias,
            child: page,
          ),
        ),
      ),
    );
  }

  Widget _header(AppTokens tokens, bool compact) {
    final gutter = compact ? AppSpacing.s16 : AppSpacing.s24;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, AppSpacing.s16, gutter, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              label: 'Step ${step + 1} of $stepCount',
              child: ExcludeSemantics(
                child: Row(
                  spacing: AppSpacing.s8,
                  children: [
                    for (var i = 0; i < stepCount; i++)
                      _Dot(on: i <= step, tokens: tokens),
                  ],
                ),
              ),
            ),
          ),
          AppButton(
            label: 'Skip setup',
            variant: AppButtonVariant.ghost,
            size: compact ? AppButtonSize.lg : AppButtonSize.md,
            onPressed: onSkip,
          ),
        ],
      ),
    );
  }

  Widget _scrollingBody(AppTokens tokens, bool compact) {
    final gutter = compact ? AppSpacing.s16 : AppSpacing.s24;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, AppSpacing.s24, gutter, gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppSpacing.s8),
            Text(
              subtitle!,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.s20),
          AppFadeIn(key: ValueKey(step), child: body),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.s12),
            AppErrorState(message: error!),
          ],
        ],
      ),
    );
  }

  Widget _actions(AppTokens tokens, bool compact) {
    final inset = compact ? AppSpacing.s12 : AppSpacing.s16;
    final size = compact ? AppButtonSize.lg : AppButtonSize.md;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Padding(
        padding: EdgeInsets.all(inset),
        child: Row(
          spacing: AppSpacing.s8,
          children: [
            if (onBack != null)
              AppButton(label: 'Back', size: size, onPressed: onBack),
            const Spacer(),
            AppButton(
              label: continueLabel,
              variant: AppButtonVariant.primary,
              size: size,
              busy: busy,
              focusNode: continueFocus,
              onPressed: onContinue,
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.on, required this.tokens});

  final bool on;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.reduced(context, AppMotion.base),
      width: on ? 20 : 8,
      height: 4,
      decoration: BoxDecoration(
        color: on ? tokens.accent : tokens.borderStrong,
        borderRadius: BorderRadius.circular(AppRadii.full),
      ),
    );
  }
}
