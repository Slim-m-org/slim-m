// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pill that says a newer web build is live (see `web_update_watch.dart`).
///
/// Mounted once by `appChromeBuilder`, outside the routed tree, top-centre at
/// every width (below the app bar on a narrow window): bottom-left is the
/// account and voice panel in a wide window, bottom-right is the toasts', and
/// the bottom of a phone is the composer.
/// Reload is the only thing that reloads, and dismissing hides it until a
/// newer build than the one dismissed appears.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import 'web_page.dart';
import 'web_update_watch.dart';

class WebUpdatePill extends ConsumerWidget {
  const WebUpdatePill({super.key, this.onReload = reloadPage});

  final VoidCallback onReload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(webUpdateSupportedProvider)) return const SizedBox.shrink();
    ref.watch(webUpdateWatcherProvider);
    if (!ref.watch(webUpdateAvailableProvider)) return const SizedBox.shrink();

    // Below the app bar on a narrow window, so it never covers the header's actions.
    final clearOfHeader = MediaQuery.sizeOf(context).width < kCompactWidth
        ? kToolbarHeight
        : 0.0;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.all(
            AppSpacing.s16,
          ).copyWith(top: AppSpacing.s16 + clearOfHeader),
          child: _Pill(
            onReload: onReload,
            onDismiss: () =>
                ref.read(dismissedWebBuildProvider.notifier).state = ref.read(
                  liveWebBuildProvider,
                ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.onReload, required this.onDismiss});

  final VoidCallback onReload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final height = AppTouchTargets.of(context) ? 44.0 : 36.0;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        liveRegion: true,
        container: true,
        child: Container(
          height: height,
          padding: const EdgeInsets.only(left: AppSpacing.s16),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadii.full),
            border: Border.all(color: tokens.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.retry, size: AppSizes.icon16, color: tokens.accent),
              const SizedBox(width: AppSpacing.s8),
              Flexible(
                child: Text(
                  'New version available',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              AppButton(
                label: 'Reload',
                variant: AppButtonVariant.soft,
                size: AppButtonSize.sm,
                onPressed: onReload,
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Dismiss',
                size: AppIconButtonSize.sm,
                onPressed: onDismiss,
              ),
              const SizedBox(width: AppSpacing.s4),
            ],
          ),
        ),
      ),
    );
  }
}
