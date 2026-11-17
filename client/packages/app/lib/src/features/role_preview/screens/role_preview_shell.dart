// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the signed-in shell shows while previewing a role (decision 0124): the banner, the
/// role's rail and a channel's summary. No composer, no menus, no messages.
///
/// At compact width the rail and the summary are one pane at a time with a back action
/// (`docs/design/desktop-vs-mobile.md`, the three widths); above it they sit side by side.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../widgets/banner_host_layout.dart';
import '../../channels/widgets/channel_rail.dart' show ChannelRail;
import '../providers/role_preview_controller.dart';
import '../widgets/role_preview_banner.dart';
import '../widgets/role_preview_rail.dart';
import '../widgets/role_preview_summary.dart';

class RolePreviewShell extends ConsumerWidget {
  const RolePreviewShell({super.key, required this.session});

  final RolePreviewSession session;

  /// Shown beside the rail until a channel is picked.
  static const pickPrompt =
      'Pick a channel to see what this role can do there.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final controller = ref.read(rolePreviewProvider.notifier);
    return Material(
      color: tokens.surfaceBase,
      child: BannerHostLayout(
        banner: SafeArea(
          bottom: false,
          child: RolePreviewBanner(
            roleName: session.roleName,
            onExit: controller.exit,
          ),
        ),
        child: SafeArea(
          top: false,
          child: switch (session.preview) {
            AsyncData(:final value) => _Loaded(
              session: session,
              preview: value,
            ),
            AsyncError(:final error) => Center(
              child: AppErrorState(
                message: _describe(error),
                onRetry: controller.retry,
              ),
            ),
            _ => const Center(
              child: AppSpinner(semanticLabel: 'Loading the preview'),
            ),
          },
        ),
      ),
    );
  }

  String _describe(Object error) => error is api.ApiException
      ? describeApiFailure('open the preview', error)
      : 'Could not open the preview.';
}

class _Loaded extends ConsumerWidget {
  const _Loaded({required this.session, required this.preview});

  final RolePreviewSession session;
  final api.RolePreview preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final controller = ref.read(rolePreviewProvider.notifier);
    final open = session.openChannel;
    final rail = RolePreviewRail(
      preview: preview,
      selectedId: open?.id,
      onOpen: controller.open,
    );
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    if (compact) {
      if (open == null) return rail;
      return RolePreviewSummary(
        roleName: session.roleName,
        channel: open,
        onBack: controller.close,
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: ChannelRail.expandedWidth,
          color: tokens.surfaceSunken,
          child: rail,
        ),
        Expanded(
          child: open == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.s24),
                    child: Text(
                      RolePreviewShell.pickPrompt,
                      textAlign: TextAlign.center,
                      style: AppText.ui.copyWith(color: tokens.textSecondary),
                    ),
                  ),
                )
              : RolePreviewSummary(roleName: session.roleName, channel: open),
        ),
      ],
    );
  }
}
