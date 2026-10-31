// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one place a viewer chooses between the shared stream and playing the
/// title themselves, and the one line that says why they cannot.
///
/// A banner under the position bar, which is rule 6 in
/// `docs/design/desktop-vs-mobile.md`: it pushes content and never overlays
/// it. An ineligible viewer sees what failed and what fixes it, never nothing.
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/direct_play_controller.dart';
import '../providers/direct_play_eligibility.dart';
import '../providers/direct_play_provider.dart';
import '../providers/watch_room.dart';
import 'direct_play_sign_in_sheet.dart';

class DirectPlayPanel extends ConsumerWidget {
  const DirectPlayPanel({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offered =
        ref.watch(watchRoomProvider(channelId)).valueOrNull?.directPlay != null;
    if (!offered) return const SizedBox.shrink();
    final controller = ref.read(directPlayProvider(channelId).notifier);
    final state = ref.watch(directPlayProvider(channelId));
    ref.listen<DirectPlayState>(directPlayProvider(channelId), (before, now) {
      final asked =
          now.phase == DirectPlayPhase.signIn &&
          before?.phase != DirectPlayPhase.signIn;
      if (asked) unawaited(showDirectPlaySignIn(context, controller));
    });
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: _Row(state: state, controller: controller),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.state, required this.controller});

  final DirectPlayState state;
  final DirectPlayController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final block = state.block;
    final line =
        state.notice ?? (block == null ? null : directPlayBlockLine(block));
    final retry =
        state.notice != null ||
        block == DirectPlayBlock.unreachable ||
        block == DirectPlayBlock.cannotSee;
    return Container(
      constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
      padding: const EdgeInsets.symmetric(
        vertical: AppSpacing.s4,
        horizontal: AppSpacing.s12,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          Icon(
            line == null ? AppIcons.play : AppIcons.info,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
          Expanded(
            child: Text(
              line ?? 'Watch at source quality',
              style: AppText.caption.copyWith(
                color: line == null ? tokens.textPrimary : tokens.textSecondary,
              ),
            ),
          ),
          if (state.checking)
            const AppSpinner()
          else if (retry)
            AppButton(
              label: state.notice != null ? 'Try again' : 'Check again',
              variant: AppButtonVariant.ghost,
              size: AppButtonSize.sm,
              onPressed: () => unawaited(controller.recheck()),
            )
          else if (block == null)
            AppToggle(
              value: state.enabled,
              semanticLabel: 'Watch at source quality',
              onChanged: (on) =>
                  unawaited(on ? controller.enable() : controller.disable()),
            ),
        ],
      ),
    );
  }
}
