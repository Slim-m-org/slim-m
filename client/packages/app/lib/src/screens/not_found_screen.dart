// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What an address that matches no route shows, in the app's own voice rather
/// than the router's exception text.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../routing/routes.dart';

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _LostChannel(),
                  const SizedBox(height: AppSpacing.s24),
                  Text(
                    'Nothing lives here',
                    textAlign: TextAlign.center,
                    style: AppText.heading.copyWith(color: tokens.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  Text(
                    'The link may be mistyped, or the page may have moved. '
                    'Your conversations are right where you left them.',
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: tokens.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.s24),
                  AppButton(
                    label: 'Back to channels',
                    icon: AppIcons.back,
                    variant: AppButtonVariant.primary,
                    size: AppButtonSize.lg,
                    onPressed: () => context.go(Routes.channels),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A channel mark with a search glass on its corner: the thing you looked for.
class _LostChannel extends StatelessWidget {
  const _LostChannel();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: Center(
        child: SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            alignment: Alignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox(width: 88, height: 88),
              ),
              Icon(AppIcons.hash, size: AppSizes.icon32, color: tokens.accent),
              Positioned(
                right: 0,
                bottom: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surfaceRaised,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.borderSubtle),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.s8),
                    child: Icon(
                      AppIcons.search,
                      size: AppSizes.icon24,
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
