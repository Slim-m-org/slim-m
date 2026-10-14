// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An attachment its sender marked as a spoiler: drawn blurred and inert
/// under a "Spoiler" pill until the viewer chooses to look. The text spoiler
/// (`message_spoiler.dart`) is the same idea for words.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

const double _minWidth = 160;
const double _minHeight = 96;

class AttachmentSpoilerCover extends StatelessWidget {
  const AttachmentSpoilerCover({
    super.key,
    required this.filename,
    required this.onReveal,
    required this.child,
  });

  final String filename;
  final VoidCallback onReveal;

  /// The attachment as it would render, blurred and unable to take input.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: 'Spoiler, $filename. Activate to show it.',
      onTap: onReveal,
      excludeSemantics: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onReveal();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            onReveal();
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.control),
            child: Stack(
              children: [
                // Room for the pill even before the image has loaded, or behind a tiny one.
                const SizedBox(width: _minWidth, height: _minHeight),
                IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: child,
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    color: tokens.surfaceBase.withValues(alpha: 0.35),
                  ),
                ),
                Positioned.fill(
                  child: Center(child: _SpoilerPill(tokens: tokens)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpoilerPill extends StatelessWidget {
  const _SpoilerPill({required this.tokens});

  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.s12,
      vertical: AppSpacing.s4,
    ),
    decoration: BoxDecoration(
      color: tokens.surfaceRaised,
      border: Border.all(color: tokens.borderStrong),
      borderRadius: BorderRadius.circular(AppRadii.full),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          AppIcons.spoiler,
          size: AppSizes.icon16,
          color: tokens.textPrimary,
        ),
        const SizedBox(width: AppSpacing.s4),
        Text(
          'Spoiler',
          style: AppText.ui.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
      ],
    ),
  );
}
