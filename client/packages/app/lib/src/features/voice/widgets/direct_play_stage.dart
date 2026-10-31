// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The viewer's own player, mounted in the slot the bot's screen share
/// renders in, so the two shapes swap in one place.
///
/// A local pause is local and says so, with one action to rejoin the room.
/// See docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/direct_play_controller.dart';
import '../providers/direct_play_provider.dart';

class DirectPlayStage extends ConsumerWidget {
  const DirectPlayStage({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final state = ref.watch(directPlayProvider(channelId));
    final controller = ref.read(directPlayProvider(channelId).notifier);
    final player = controller.player;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (player != null) player.buildVideo(),
            if (state.phase == DirectPlayPhase.connecting)
              _Note(
                icon: null,
                text: 'Starting at source quality',
                tokens: tokens,
              ),
            if (state.localPause != null)
              _PausedBand(
                roomAt: state.localPause!,
                onRejoin: () => unawaited(controller.rejoin()),
                tokens: tokens,
              ),
            if (state.phase == DirectPlayPhase.playing &&
                state.localPause == null)
              Positioned(
                right: AppSpacing.s8,
                bottom: AppSpacing.s8,
                child: AppIconButton(
                  icon: AppIcons.pause,
                  semanticLabel: 'Pause for me only',
                  onPressed: () => unawaited(controller.pauseLocally()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, required this.tokens});

  final IconData? icon;
  final String text;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Center(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        if (icon == null)
          const AppSpinner()
        else
          Icon(icon, size: AppSizes.icon16),
        Text(text, style: AppText.caption.copyWith(color: Colors.white70)),
      ],
    ),
  );
}

class _PausedBand extends StatelessWidget {
  const _PausedBand({
    required this.roomAt,
    required this.onRejoin,
    required this.tokens,
  });

  final Duration roomAt;
  final VoidCallback onRejoin;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: Container(
      constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s8,
      ),
      color: Colors.black87,
      child: Row(
        spacing: AppSpacing.s12,
        children: [
          const Icon(
            AppIcons.pause,
            size: AppSizes.icon16,
            color: Colors.white70,
          ),
          Expanded(
            child: Text(
              directPlayPauseLine(roomAt),
              style: AppText.caption.copyWith(color: Colors.white),
            ),
          ),
          AppButton(
            label: 'Rejoin the room',
            size: AppButtonSize.sm,
            onPressed: onRejoin,
          ),
        ],
      ),
    ),
  );
}
