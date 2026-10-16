// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting pane: the device check and, beside a nav, the debug
/// log as an inner page of the same pane.
///
/// A phone has no room for a second level inside a pane, so the row pushes the
/// standalone debug log route there instead. Which one happens follows the
/// window width, never the platform.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../diagnostics/debug_log.dart';
import '../routing/breakpoints.dart';
import '../routing/routes.dart';
import 'debug_log_page.dart';
import 'media_capability_section.dart';
import 'settings_icon_tile.dart';
import 'settings_panes.dart';

/// Whether the debug log is showing inside the pane; dropped with the pane.
final debugLogOpenProvider = StateProvider.autoDispose<bool>((ref) => false);

bool _isWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;

class TroubleshootingPane extends ConsumerWidget {
  const TroubleshootingPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(debugLogOpenProvider) && _isWide(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Offstage keeps the check's result while the log is open.
        Offstage(
          offstage: open,
          child: const MediaCapabilitySection(extraRows: [_DebugLogRow()]),
        ),
        if (open) const DebugLogPage(),
      ],
    );
  }
}

class _DebugLogRow extends ConsumerWidget {
  const _DebugLogRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(debugLogProvider).length;
    return AppListRow(
      leading: const SettingsIconTile(AppIcons.debugLog),
      label: 'Debug log',
      subtitle: count == 0 ? 'Nothing caught this session.' : '$count caught.',
      trailing: const Icon(AppIcons.chevronRight, size: AppSizes.icon16),
      onTap: () {
        if (_isWide(context)) {
          ref.read(debugLogOpenProvider.notifier).state = true;
        } else {
          unawaited(context.push(Routes.debugLog));
        }
      },
    );
  }
}

/// The pane heading: plain while the log is closed, a breadcrumb with the
/// log's actions while it is open.
class TroubleshootingHeading extends ConsumerWidget {
  const TroubleshootingHeading({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(debugLogOpenProvider)) {
      return SettingsPaneHeading('Troubleshooting', onClose: onClose);
    }
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final empty = ref.watch(debugLogProvider).isEmpty;
    void back() => ref.read(debugLogOpenProvider.notifier).state = false;

    return SizedBox(
      height: 40,
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          AppIconButton(
            icon: AppIcons.back,
            semanticLabel: 'Back to troubleshooting',
            tooltip: 'Back to troubleshooting',
            iconSize: AppSizes.icon16,
            onPressed: back,
          ),
          Flexible(
            child: GestureDetector(
              onTap: back,
              child: Text(
                'Troubleshooting',
                overflow: TextOverflow.ellipsis,
                style: AppText.body.copyWith(color: tokens.textSecondary),
              ),
            ),
          ),
          Text(
            '/',
            style: AppText.heading.copyWith(color: tokens.textSecondary),
          ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Debug log',
                overflow: TextOverflow.ellipsis,
                style: AppText.heading.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ),
          ),
          AppButton(
            label: 'Copy all',
            icon: AppIcons.copy,
            onPressed: empty
                ? null
                : () => unawaited(copyDebugLog(context, ref)),
          ),
          AppButton(
            label: 'Clear',
            variant: AppButtonVariant.ghost,
            onPressed: empty ? null : ref.read(debugLogProvider.notifier).clear,
          ),
        ],
      ),
    );
  }
}
